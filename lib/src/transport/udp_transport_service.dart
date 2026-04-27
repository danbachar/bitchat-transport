import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:redux/redux.dart';
import 'package:dart_udx/dart_udx.dart';

import '../transport/transport_service.dart';
import '../transport/address_utils.dart';
import '../models/identity.dart';
import '../protocol/protocol_handler.dart';
import '../store/store.dart';

enum UdpConnectFailureKind {
  networkUnreachable,
  handshakeTimeout,
  other,
}

/// Display info for UDP transport
const _defaultUdpDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'Direct UDP peer-to-peer transport',
  color: Colors.green,
);

/// UDP transport service using dart_udx for reliable streams over UDP.
///
/// Uses Bitchat's Ed25519 identity directly. Addressing uses simple
/// ip:port strings.
///
/// ## Dual sockets
///
/// We bind two wildcard sockets — one to `::` (IPv6) and one to `0.0.0.0`
/// (IPv4). Each has its own [UDXMultiplexer]; outgoing connections and raw
/// sends pick the socket matching the destination address family. Either
/// socket may fail to bind (e.g. no v4 stack on the device); the transport
/// stays usable as long as one of them is bound.
///
/// ## Lifecycle
///
/// Two-phase initialization to support hole-punching:
///
/// 1. [initialize] — binds the wildcard sockets so [rawSocket] /
///    [rawSocketV4] are available for hole-punch packets.
/// 2. [startMultiplexer] — creates per-socket UDX multiplexers. After this,
///    incoming UDP reads flow through UDX. Stray non-UDX packets are
///    handled by the raw-packet fallback.
///
/// ## Connection Identity
///
/// The first message on any new UDX stream MUST be a BitchatPacket of type ANNOUNCE.
/// This allows the receiver to map the UDX connection to a Bitchat public key.
/// (Future: Noise XX handshake will replace this.)
///
/// ## No Store-and-Forward
///
/// Messages to unreachable peers fail immediately. No caching, no relaying.
class UdpTransportService extends TransportService {
  static const Duration _defaultHandshakeTimeout = Duration(seconds: 10);

  /// Our Bitchat identity (Ed25519 keypair)
  final BitchatIdentity identity;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol handler for encoding/decoding
  final ProtocolHandler protocolHandler;

  // --- Socket and UDX state ---

  /// The IPv6 wildcard raw UDP socket. UDX wraps it; we own it.
  RawDatagramSocket? _rawSocketV6;

  /// The IPv4 wildcard raw UDP socket.
  RawDatagramSocket? _rawSocketV4;

  /// UDX factory instance
  UDX? _udx;

  /// Multiplexer for the IPv6 socket. Created in [startMultiplexer].
  UDXMultiplexer? _multiplexerV6;

  /// Multiplexer for the IPv4 socket. Created in [startMultiplexer].
  UDXMultiplexer? _multiplexerV4;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  // --- Peer connections ---

  /// Active UDX connections per peer, keyed by pubkey hex.
  final Map<String, _PeerConnection> _peerConnections = {};

  // Stream IDs: each UDPSocket (connection) has its own ID space.
  // We use stream ID 1 for our outgoing stream on every connection.
  // The remote peer also uses stream ID 1 for theirs.
  // Since stream IDs are scoped to a UDPSocket, there's no collision.
  static const int _outgoingStreamId = 1;
  static const int _expectedIncomingStreamId = 1;

  // --- Stream controllers ---

  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // --- Subscriptions ---

  StreamSubscription? _multiplexerConnectionsSubV6;
  StreamSubscription? _multiplexerConnectionsSubV4;

  // --- Public callbacks ---

  /// Called when data is received from a UDP peer.
  /// The coordinator deserializes as BitchatPacket and routes via MessageRouter.
  void Function(String pubkeyHex, Uint8List data)? onUdpDataReceived;

  /// Timeout for UDX handshake completion.
  final Duration connectHandshakeTimeout;

  UdpConnectFailureKind? _lastConnectFailureKind;

  UdpTransportService({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    this.connectHandshakeTimeout = _defaultHandshakeTimeout,
  });

  // ===== Public Getters =====

  /// The IPv6 raw UDP socket — exposed for hole-punch service to send punch
  /// packets. Only use for raw sends; DO NOT read after [startMultiplexer].
  RawDatagramSocket? get rawSocket => _rawSocketV6;

  /// The IPv4 raw UDP socket. Same caveats as [rawSocket].
  RawDatagramSocket? get rawSocketV4 => _rawSocketV4;

  /// Pick the raw socket appropriate for the given destination family.
  RawDatagramSocket? rawSocketFor(InternetAddressType family) {
    if (family == InternetAddressType.IPv6) return _rawSocketV6;
    if (family == InternetAddressType.IPv4) return _rawSocketV4;
    return null;
  }

  /// Our bound IPv6 port (null if v6 socket failed to bind).
  int? get localPortV6 => _rawSocketV6?.port;

  /// Our bound IPv4 port (null if v4 socket failed to bind).
  int? get localPortV4 => _rawSocketV4?.port;

  /// Backwards-compatible accessor — returns the IPv6 port if available, else
  /// the IPv4 port. Hole-punch and signaling use this when no destination
  /// family is yet known.
  int? get localPort => localPortV6 ?? localPortV4;

  /// Set of address families for which we have a bound socket.
  Set<InternetAddressType> get activeAddressTypes => {
        if (_rawSocketV6 != null) InternetAddressType.IPv6,
        if (_rawSocketV4 != null) InternetAddressType.IPv4,
      };

  /// Whether we currently have any usable local UDP route.
  ///
  /// True once at least one wildcard socket is bound. We don't enumerate
  /// interfaces to "verify" reachability — the canonical "can we be reached"
  /// answer comes from the reflected public address, updated asynchronously
  /// via signaling.
  bool get hasUsableRoute => activeAddressTypes.isNotEmpty;

  /// Classification of the most recent outbound connect failure, if any.
  UdpConnectFailureKind? get lastConnectFailureKind => _lastConnectFailureKind;

  /// Whether at least one UDX multiplexer is active (accepting streams).
  bool get isMultiplexerActive =>
      _multiplexerV6 != null || _multiplexerV4 != null;

  UDXMultiplexer? _multiplexerFor(InternetAddressType family) {
    if (family == InternetAddressType.IPv6) return _multiplexerV6;
    if (family == InternetAddressType.IPv4) return _multiplexerV4;
    return null;
  }

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.udp;
  @override
  TransportDisplayInfo get displayInfo => _defaultUdpDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => _peerConnections.length;

  @override
  bool get isActive => _state == TransportState.active;

  // ===== Lifecycle =====

  /// Phase 1: Bind both wildcard sockets (IPv6 `::` and IPv4 `0.0.0.0`).
  ///
  /// Each socket is bound independently — failure of one doesn't prevent
  /// the other from being usable. The transport is considered ready as
  /// long as at least one socket is bound.
  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      debugPrint('UDP transport already initialized');
      return _state.isUsable;
    }

    _setState(TransportState.initializing);
    debugPrint('Initializing UDP transport (dual-stack)');

    _udx = UDX();

    try {
      _rawSocketV6 =
          await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
      debugPrint('UDP IPv6 wildcard bound on port ${_rawSocketV6!.port}');
    } catch (e) {
      debugPrint('Failed to bind IPv6 UDP socket: $e');
    }

    try {
      _rawSocketV4 =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('UDP IPv4 wildcard bound on port ${_rawSocketV4!.port}');
    } catch (e) {
      debugPrint('Failed to bind IPv4 UDP socket: $e');
    }

    if (_rawSocketV6 == null && _rawSocketV4 == null) {
      debugPrint('No UDP socket could be bound');
      _setState(TransportState.error);
      return false;
    }

    _setState(TransportState.ready);
    return true;
  }

  /// Phase 2: Create UDX multiplexers on the bound sockets.
  ///
  /// One multiplexer per family. After this call:
  /// - All incoming UDP reads go through the corresponding multiplexer
  /// - DO NOT read from the raw sockets directly
  /// - You CAN still send raw bytes via the raw sockets (for punch packets)
  /// - Non-UDX packets are routed via [_handleRawPacket]
  ///
  /// Call this:
  /// - Immediately after [initialize] if well-connected (no NAT)
  /// - After hole-punch succeeds if behind NAT
  void startMultiplexer() {
    if (_multiplexerV6 == null && _rawSocketV6 != null) {
      _multiplexerV6 = UDXMultiplexer(_rawSocketV6!);
      _multiplexerV6!.onRawPacket = _handleRawPacket;
      _multiplexerConnectionsSubV6 =
          _multiplexerV6!.connections.listen(_handleIncomingConnection);
      debugPrint('UDX IPv6 multiplexer started on port ${_rawSocketV6!.port}');
    }
    if (_multiplexerV4 == null && _rawSocketV4 != null) {
      _multiplexerV4 = UDXMultiplexer(_rawSocketV4!);
      _multiplexerV4!.onRawPacket = _handleRawPacket;
      _multiplexerConnectionsSubV4 =
          _multiplexerV4!.connections.listen(_handleIncomingConnection);
      debugPrint('UDX IPv4 multiplexer started on port ${_rawSocketV4!.port}');
    }
    if (_multiplexerV6 != null || _multiplexerV4 != null) {
      _setState(TransportState.active);
    }
  }

  @override
  Future<void> start() async {
    // For compatibility with TransportService interface.
    // If no multiplexer exists yet but a socket is bound, start them now.
    final v6Ready = _rawSocketV6 != null && _multiplexerV6 == null;
    final v4Ready = _rawSocketV4 != null && _multiplexerV4 == null;
    if (v6Ready || v4Ready) {
      startMultiplexer();
    } else if (_state == TransportState.ready) {
      _setState(TransportState.active);
    }
  }

  @override
  Future<void> stop() async {
    debugPrint('Stopping UDP transport');

    // Close all peer connections (copy keys to avoid concurrent modification)
    final peerKeys = _peerConnections.keys.toList();
    for (final key in peerKeys) {
      final conn = _peerConnections.remove(key);
      try {
        await conn?.stream?.close();
      } catch (e) {
        debugPrint('Error closing stream for $key: $e');
      }
    }

    await _multiplexerConnectionsSubV6?.cancel();
    await _multiplexerConnectionsSubV4?.cancel();
    _multiplexerConnectionsSubV6 = null;
    _multiplexerConnectionsSubV4 = null;

    // Clear connection tracking maps
    _tempKeyToPubkey.clear();
    _addressToPubkey.clear();
    _pendingIncoming.clear();

    // We don't close the raw sockets here — they might be reused.
    // The multiplexers are discarded; new ones can be created.
    _multiplexerV6 = null;
    _multiplexerV4 = null;

    if (_state == TransportState.active) {
      _setState(TransportState.ready);
    }
    debugPrint('UDP transport stopped');
  }

  @override
  Future<void> dispose() async {
    debugPrint('Disposing UDP transport');
    await stop();

    _rawSocketV6?.close();
    _rawSocketV4?.close();
    _rawSocketV6 = null;
    _rawSocketV4 = null;
    _udx = null;

    _state = TransportState.disposed;

    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
  }

  // ===== Connections =====

  /// Connect to a peer at a known ip:port.
  ///
  /// Creates a UDX connection (UDPSocket) and stream to the peer using the
  /// multiplexer for the destination address family.
  /// The first message sent MUST be an ANNOUNCE packet (caller's responsibility).
  ///
  /// Returns true if the connection was established.
  Future<bool> connectToPeer(
      String pubkeyHex, InternetAddress addr, int port) async {
    _lastConnectFailureKind = null;

    final multiplexer = _multiplexerFor(addr.type);
    if (multiplexer == null) {
      debugPrint(
          'Cannot connect: no ${addr.type == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
          'multiplexer started for $pubkeyHex');
      _lastConnectFailureKind = UdpConnectFailureKind.networkUnreachable;
      return false;
    }

    if (_peerConnections.containsKey(pubkeyHex)) {
      debugPrint('Already connected to $pubkeyHex');
      return true;
    }

    if (!canDialAddress(addr)) {
      _lastConnectFailureKind = UdpConnectFailureKind.networkUnreachable;
      debugPrint('Cannot connect to $pubkeyHex: no usable '
          '${addr.type == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
          'route for ${addr.address}:$port');
      return false;
    }

    UDPSocket? udpSocket;
    StreamSubscription? socketErrorsSub;
    Object? lastSocketError;
    final connectCompleter = Completer<UDXStream>();
    try {
      final remoteHost = addr.address;

      // Store address → pubkey mapping so incoming connections from this
      // address can be immediately associated with the correct peer.
      _addressToPubkey['$remoteHost:$port'] = pubkeyHex;

      // Create UDX connection on the family-specific multiplexer.
      udpSocket = multiplexer.createSocket(_udx!, remoteHost, port);
      final socket = udpSocket;
      socketErrorsSub = udpSocket.on('error').listen((event) {
        final data = event.data;
        if (data is Map && data['error'] != null) {
          lastSocketError = data['error'];
          if (!connectCompleter.isCompleted) {
            connectCompleter.completeError(data['error']);
          }
        }
      });

      // Create the outgoing stream and wait for handshake inside a guarded
      // zone so low-level async socket send failures are captured as a normal
      // connect failure instead of escaping to Flutter's top-level handler.
      runZonedGuarded(() async {
        try {
          final stream = await UDXStream.createOutgoing(
            _udx!,
            socket,
            _outgoingStreamId,
            _expectedIncomingStreamId,
            remoteHost,
            port,
          );

          // Wait for UDX handshake to complete, with timeout.
          // Without this timeout, the await hangs forever if the remote is
          // unreachable (firewall, wrong address), leaking UDX sockets and
          // preventing the auto-connect from ever succeeding.
          await socket.handshakeComplete.timeout(
            connectHandshakeTimeout,
            onTimeout: () {
              throw TimeoutException(
                'UDX handshake timed out after '
                '${connectHandshakeTimeout.inSeconds}s',
              );
            },
          );
          if (!connectCompleter.isCompleted) {
            connectCompleter.complete(stream);
          }
        } catch (error, stackTrace) {
          lastSocketError ??= error;
          if (!connectCompleter.isCompleted) {
            connectCompleter.completeError(error, stackTrace);
          }
        }
      }, (error, stackTrace) {
        lastSocketError ??= error;
        if (!connectCompleter.isCompleted) {
          connectCompleter.completeError(error, stackTrace);
        }
      });

      final stream = await connectCompleter.future;

      // Store the connection
      _peerConnections[pubkeyHex] = _PeerConnection(
        pubkeyHex: pubkeyHex,
        udpSocket: udpSocket,
        stream: stream,
        addr: addr,
        port: port,
      );

      // Listen for data on the outgoing stream (receives paired incoming data)
      _listenToStream(pubkeyHex, stream);

      // Also listen for additional incoming streams on this UDPSocket.
      // In a simultaneous open, the remote peer might send data on our
      // connection rather than creating their own.
      udpSocket.on('stream').listen((UDXEvent event) {
        final incomingStream = event.data as UDXStream;
        if (incomingStream != stream) {
          debugPrint(
              'Incoming stream ${incomingStream.id} on outgoing connection to $pubkeyHex');
          _listenToStream(pubkeyHex, incomingStream);
        }
      });
      udpSocket.flushStreamBuffer();

      debugPrint('Connected to peer $pubkeyHex at $remoteHost:$port');

      _connectionController.add(TransportConnectionEvent(
        peerId: pubkeyHex,
        transport: TransportType.udp,
        connected: true,
        isIncoming: false,
      ));

      _lastConnectFailureKind = null;
      return true;
    } catch (e) {
      _lastConnectFailureKind = _classifyConnectFailure(lastSocketError ?? e);
      debugPrint('Failed to connect to peer $pubkeyHex: $e');

      // Clean up the UDX socket on failure to prevent resource leaks.
      // Without this, each failed attempt leaves a dangling socket in the
      // multiplexer that never gets garbage collected.
      if (udpSocket != null) {
        try {
          await udpSocket.close();
        } catch (_) {}
      }
      // Remove stale address mapping
      _addressToPubkey.remove('${addr.address}:$port');

      return false;
    } finally {
      await socketErrorsSub?.cancel();
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    final conn = _peerConnections[peerId];
    if (conn == null || conn.stream == null) {
      debugPrint('Cannot send to $peerId: not connected');
      return false;
    }

    try {
      await conn.stream!.add(data);
      debugPrint('Sent ${data.length} bytes to peer $peerId');
      return true;
    } catch (e) {
      debugPrint('Failed to send to peer $peerId: $e');
      return false;
    }
  }

  // ===== Raw UDP fallback (bypasses UDX) =====

  /// Peers we communicate with via raw UDP (when UDX handshake fails).
  /// Key: pubkeyHex, Value: target address info.
  final Map<String, AddressInfo> _rawPeerAddresses = {};

  /// Send data via raw UDP to a peer, bypassing UDX entirely.
  ///
  /// Uses the socket matching the destination's address family.
  /// Use this when UDX connectToPeer fails (e.g. hairpin routing on same LAN).
  /// No reliability — packets may be lost, duplicated, or reordered.
  /// The application layer handles retries via ACKs.
  bool sendRawTo(
      String pubkeyHex, InternetAddress ip, int port, Uint8List data) {
    final socket = rawSocketFor(ip.type);
    if (socket == null) return false;
    try {
      final sent = socket.send(data, ip, port);
      if (sent > 0) {
        // Track this as a raw peer so broadcast can include them
        _rawPeerAddresses[pubkeyHex] = AddressInfo(ip, port);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Raw UDP send failed to $pubkeyHex: $e');
      return false;
    }
  }

  /// Check if a peer has a raw UDP address (fallback mode).
  AddressInfo? getRawPeerAddress(String pubkeyHex) =>
      _rawPeerAddresses[pubkeyHex];

  @override
  Future<void> broadcast(Uint8List data, {Set<String>? excludePeerIds}) async {
    // Send via UDX connections
    for (final entry in _peerConnections.entries) {
      if (excludePeerIds != null && excludePeerIds.contains(entry.key)) {
        continue;
      }
      await sendToPeer(entry.key, data);
    }
    // Also send via raw UDP to peers where UDX failed
    for (final entry in _rawPeerAddresses.entries) {
      if (excludePeerIds != null && excludePeerIds.contains(entry.key)) {
        continue;
      }
      if (_peerConnections.containsKey(entry.key)) {
        continue; // Already sent via UDX
      }
      sendRawTo(entry.key, entry.value.ip, entry.value.port, data);
    }
  }

  /// Disconnect from a specific peer.
  Future<void> disconnectFromPeer(String pubkeyHex) async {
    final conn = _peerConnections.remove(pubkeyHex);
    if (conn == null) return;

    // Clean up address mapping
    _addressToPubkey.removeWhere((_, v) => v == pubkeyHex);
    // Clean up tempKey mapping
    _tempKeyToPubkey.removeWhere((_, v) => v == pubkeyHex);

    try {
      await conn.stream?.close();
    } catch (e) {
      debugPrint('Error closing stream for $pubkeyHex: $e');
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: pubkeyHex,
      transport: TransportType.udp,
      connected: false,
      reason: 'Disconnected by request',
    ));

    debugPrint('Disconnected from peer $pubkeyHex');
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // Peer connections are already keyed by pubkey hex.
    // This is used for incoming connections where we learn the pubkey from ANNOUNCE.
    debugPrint('associatePeerWithPubkey: $peerId (managed via ANNOUNCE)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    final hex = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return _peerConnections.containsKey(hex) ? hex : null;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    final conn = _peerConnections[peerId];
    if (conn == null) return null;
    // peerId IS the pubkeyHex in our case
    final bytes = <int>[];
    for (var i = 0; i < peerId.length; i += 2) {
      bytes.add(int.parse(peerId.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  /// Get the observed remote address for a connected peer.
  ///
  /// Returns the (ip, port) as seen on the UDX connection — this is the
  /// peer's NAT-translated public address. Used by the signaling service
  /// to reflect the peer's true external address back to them.
  ///
  /// Returns null if the peer is not connected.
  ({InternetAddress ip, int port})? getRemoteAddress(String pubkeyHex) {
    final conn = _peerConnections[pubkeyHex];
    if (conn == null) return null;
    return (ip: conn.addr, port: conn.port);
  }

  // ===== Incoming Connection Handling =====

  /// Handle a new incoming UDX connection (remote peer connected to us).
  void _handleIncomingConnection(UDPSocket socket) {
    // Normalize address string to match the format stored by connectToPeer.
    final addrStr = socket.remoteAddress.address;
    final remoteAddr = '$addrStr:${socket.remotePort}';
    debugPrint('Incoming UDX connection from $remoteAddr');

    // Check if we already know who this peer is (from a prior connectToPeer call).
    // If so, bypass the tempKey indirection and set up the listener with the
    // correct pubkey immediately. This avoids the timing race where data
    // arrives before ANNOUNCE processing can map the tempKey.
    final knownPubkey = _addressToPubkey[remoteAddr];
    if (knownPubkey != null) {
      debugPrint(
          'Known peer $knownPubkey at $remoteAddr, using direct stream listener');
      socket.on('stream').listen((UDXEvent event) {
        final stream = event.data as UDXStream;
        _listenToStream(knownPubkey, stream);
      });
      socket.flushStreamBuffer();
      return;
    }

    // Unknown peer — use tempKey-based handling until ANNOUNCE reveals pubkey
    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      _handleIncomingStream(socket, stream);
    });

    // Flush any buffered streams (race condition fix from dart_udx)
    socket.flushStreamBuffer();
  }

  /// Handle an incoming stream on a connection.
  ///
  /// Any verified BitchatPacket identifies the sender via its header pubkey.
  /// The coordinator maps the connection after verifying the first packet.
  void _handleIncomingStream(UDPSocket socket, UDXStream stream) {
    debugPrint('Incoming UDX stream ${stream.id}');

    // Listen for data on this stream.
    // We don't know the pubkey yet, so we use a temporary key and let the
    // coordinator re-map after processing the first verified packet.
    final tempKey = '${socket.remoteAddress}:${socket.remotePort}:${stream.id}';

    // Store as pending until ANNOUNCE reveals the pubkey
    _pendingIncoming[tempKey] = _PeerConnection(
      pubkeyHex: '', // unknown yet
      udpSocket: socket,
      stream: stream,
      addr: socket.remoteAddress,
      port: socket.remotePort,
    );

    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;

        // Use mapped pubkey hex if ANNOUNCE has been processed, otherwise tempKey.
        // This ensures ACKs and subsequent messages use the correct peer ID
        // that matches _peerConnections.
        final effectiveId = _tempKeyToPubkey[tempKey] ?? tempKey;

        debugPrint(
            'Received ${data.length} bytes from ${socket.remoteAddress}:${socket.remotePort} (id: $effectiveId)');

        // Emit on data stream
        _dataController.add(TransportDataEvent(
          peerId: effectiveId,
          transport: TransportType.udp,
          data: data,
        ));

        // Forward to coordinator for deserialization and routing.
        // The coordinator will call back with the pubkey after ANNOUNCE processing,
        // and we'll remap the connection.
        onUdpDataReceived?.call(effectiveId, data);
      },
      onError: (e) {
        debugPrint('⚠️ UDX stream error from $tempKey: $e');
      },
      onDone: () {
        debugPrint('⚠️ UDX stream closed from $tempKey');
        // If we have a peer mapped to this temp key, clean up
        final pubkeyHex = _tempKeyToPubkey.remove(tempKey);
        if (pubkeyHex != null) {
          _peerConnections.remove(pubkeyHex);
          _connectionController.add(TransportConnectionEvent(
            peerId: pubkeyHex,
            transport: TransportType.udp,
            connected: false,
            reason: 'Stream closed',
          ));
        }
      },
    );
  }

  /// Reverse map: temp connection key → pubkey hex.
  /// Populated when ANNOUNCE is processed and we learn who connected to us.
  final Map<String, String> _tempKeyToPubkey = {};

  /// Reverse map: "remoteAddress:remotePort" → pubkey hex.
  /// Populated by [connectToPeer] so incoming connections from known addresses
  /// can be immediately associated with the correct pubkey, bypassing the
  /// tempKey indirection and avoiding the timing race where data arrives
  /// before ANNOUNCE processing completes.
  final Map<String, String> _addressToPubkey = {};

  /// Pending incoming connections not yet mapped to a pubkey.
  /// Keyed by tempKey, contains the UDPSocket + UDXStream.
  final Map<String, _PeerConnection> _pendingIncoming = {};

  /// Called by the coordinator after verifying a packet from an incoming connection.
  ///
  /// Maps the temporary connection key to the peer's pubkey hex.
  /// The coordinator calls this with the tempKey it received via [onUdpDataReceived]
  /// and the pubkey extracted from the verified packet's header.
  void mapIncomingConnectionToPubkey(String tempKey, String pubkeyHex) {
    _tempKeyToPubkey[tempKey] = pubkeyHex;

    // Move from pending to established connections
    final pending = _pendingIncoming.remove(tempKey);
    if (pending != null && !_peerConnections.containsKey(pubkeyHex)) {
      _peerConnections[pubkeyHex] = _PeerConnection(
        pubkeyHex: pubkeyHex,
        udpSocket: pending.udpSocket,
        stream: pending.stream,
        addr: pending.addr,
        port: pending.port,
      );

      _connectionController.add(TransportConnectionEvent(
        peerId: pubkeyHex,
        transport: TransportType.udp,
        connected: true,
        isIncoming: true,
      ));

      debugPrint('Mapped incoming connection $tempKey → $pubkeyHex');
    }
  }

  // ===== Raw UDP Fallback Receive =====

  /// Handle a non-UDX packet received on the multiplexer socket.
  ///
  /// This fires for packets that don't parse as valid UDX (e.g. BitchatPackets
  /// sent via [sendRawTo] from a peer where UDX handshake failed).
  /// Skip hole-punch packets (36 bytes with BCPU magic).
  void _handleRawPacket(Uint8List data, InternetAddress address, int port) {
    // Skip punch packets (36 bytes, magic "BCPU")
    if (data.length == 36 &&
        data[0] == 0x42 &&
        data[1] == 0x43 &&
        data[2] == 0x50 &&
        data[3] == 0x55) {
      return;
    }

    // Skip tiny packets that aren't meaningful
    if (data.length < 50) return;

    final addrStr = '${address.address}:$port';
    debugPrint('Raw UDP packet: ${data.length} bytes from $addrStr');

    // Try to identify the sender from _rawPeerAddresses (reverse lookup)
    String? senderPubkeyHex;
    for (final entry in _rawPeerAddresses.entries) {
      if (entry.value.ip.address == address.address &&
          entry.value.port == port) {
        senderPubkeyHex = entry.key;
        break;
      }
    }

    // Forward to coordinator for deserialization — use the pubkeyHex if known,
    // otherwise use the address string as a temporary ID.
    final effectiveId = senderPubkeyHex ?? addrStr;
    onUdpDataReceived?.call(effectiveId, data);
  }

  // ===== Stream Listening =====

  /// Listen for data on an outgoing stream (peer we connected to).
  void _listenToStream(String pubkeyHex, UDXStream stream) {
    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;

        debugPrint('Received ${data.length} bytes from peer $pubkeyHex');

        _dataController.add(TransportDataEvent(
          peerId: pubkeyHex,
          transport: TransportType.udp,
          data: data,
        ));

        onUdpDataReceived?.call(pubkeyHex, data);
      },
      onError: (e) {
        debugPrint('⚠️ UDX stream error from $pubkeyHex: $e');
      },
      onDone: () {
        debugPrint('⚠️ UDX stream closed from $pubkeyHex');
        _peerConnections.remove(pubkeyHex);

        if (!_connectionController.isClosed) {
          _connectionController.add(TransportConnectionEvent(
            peerId: pubkeyHex,
            transport: TransportType.udp,
            connected: false,
            reason: 'Stream closed',
          ));
        }
      },
    );
  }

  // ===== Internal =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      store.dispatch(UdpTransportStateChangedAction(newState));
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }

  bool canDialAddress(InternetAddress address) {
    if (!activeAddressTypes.contains(address.type)) return false;
    if (address.isLoopback) return true;
    return true;
  }

  UdpConnectFailureKind _classifyConnectFailure(Object error) {
    if (error is TimeoutException) {
      return UdpConnectFailureKind.handshakeTimeout;
    }

    if (error is SocketException) {
      final code = error.osError?.errorCode;
      final details =
          '${error.message} ${error.osError?.message ?? ""}'.toLowerCase();
      if (code == 101 ||
          code == 113 ||
          code == 65 ||
          details.contains('network is unreachable') ||
          details.contains('no route to host') ||
          details.contains('unreachable')) {
        return UdpConnectFailureKind.networkUnreachable;
      }
    }

    return UdpConnectFailureKind.other;
  }
}

/// Internal connection state for a single peer.
class _PeerConnection {
  final String pubkeyHex;
  final UDPSocket udpSocket;
  final UDXStream? stream;
  final InternetAddress addr;
  final int port;

  _PeerConnection({
    required this.pubkeyHex,
    required this.udpSocket,
    this.stream,
    required this.addr,
    required this.port,
  });
}
