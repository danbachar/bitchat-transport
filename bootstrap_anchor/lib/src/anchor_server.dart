import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/dart_udx.dart';

import 'address_table.dart';
import 'identity.dart';
import 'packet.dart';
import 'peer_table.dart';
import 'protocol.dart';
import 'signaling_codec.dart';
import 'signaling_handler.dart';

/// The GLP rendezvous server — a lightweight, publicly-accessible agent
/// that coordinates hole-punching between peers.
///
/// Spec alignment (§7.1):
/// - Has its own independent Ed25519 keypair (generated once, persisted).
/// - Has no friends list and does not participate in the social graph.
/// - Accepts cold-call connections from any agent.
/// - Verifies friendship proofs to confirm requesting agents are friends.
/// - Observes connecting agents' public addresses (peer_address/2).
/// - Coordinates UDP hole-punches by relaying addresses.
/// - Never relays message content — only signaling metadata flows through.
///
/// The architecture is federated: anyone can run a rendezvous server,
/// and agents may use multiple servers for redundancy.
enum AnchorBindMode {
  auto,
  dual,
  ipv6,
  ipv4,
}

class AnchorServer {
  final int ipv6Port;
  final int ipv4Port;
  final String nickname;
  final String identityPath;
  final int announceIntervalSeconds;
  final AnchorBindMode bindMode;

  late AnchorIdentity _identity;
  late Protocol _protocol;
  late PeerTable _peerTable;
  late AddressTable _addressTable;
  late SignalingHandler _signalingHandler;
  late SignalingCodec _codec;

  final Map<InternetAddressType, _AnchorListener> _listeners = {};

  /// Active UDX connections per peer, keyed by pubkey hex.
  final Map<String, _PeerConnection> _peerConnections = {};

  /// Reverse map: tempKey → pubkey hex.
  final Map<String, String> _tempKeyToPubkey = {};

  /// Reverse map: "ip:port" → pubkey hex.
  final Map<String, String> _addressToPubkey = {};

  /// Pending incoming connections not yet mapped to a pubkey.
  final Map<String, _PeerConnection> _pendingIncoming = {};

  Timer? _announceTimer;
  Timer? _staleCleanupTimer;
  Timer? _statsTimer;

  AnchorServer({
    required this.nickname,
    required this.identityPath,
    this.announceIntervalSeconds = 30,
    this.bindMode = AnchorBindMode.dual,
    this.ipv6Port = 9516,
    this.ipv4Port = 9514,
  });

  Future<void> start() async {
    _log('Starting GLP Rendezvous Server...');

    // Load or generate identity
    _identity = await AnchorIdentity.loadOrCreate(
      path: identityPath,
      nickname: nickname,
    );
    _log('Identity pubkey: ${_identity.pubkeyHex}');

    _protocol = Protocol(identity: _identity);
    _peerTable = PeerTable();
    _addressTable = AddressTable();
    _codec = const SignalingCodec();

    _signalingHandler = SignalingHandler(
      protocol: _protocol,
      peerTable: _peerTable,
      addressTable: _addressTable,
      codec: _codec,
    );
    _signalingHandler.sendSignaling = _sendSignaling;

    await _bindListenersAndDiscoverAddresses();
    for (final listener in _listeners.values) {
      listener.multiplexer = UDXMultiplexer(listener.rawSocket);
      listener.multiplexer!.onRawPacket = (data, address, port) =>
          _handleRawPacket(listener, data, address, port);
      listener.connectionsSub = listener.multiplexer!.connections.listen(
        (socket) => _handleIncomingConnection(listener, socket),
      );
      _log('UDP socket bound on port ${listener.port} '
          '(${listener.family == InternetAddressType.IPv6 ? "IPv6" : "IPv4"})');
      _log('UDX multiplexer started on port ${listener.port}');
    }

    // Periodic ANNOUNCE to all connected peers
    _announceTimer = Timer.periodic(
      Duration(seconds: announceIntervalSeconds),
      (_) => _broadcastAnnounce(),
    );

    // Periodic stale entry cleanup
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        _addressTable.removeStale(const Duration(minutes: 5));
        _peerTable.removeStale(const Duration(minutes: 30));
      },
    );

    // Periodic stats
    _statsTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _printStats(),
    );

    _log('Rendezvous server ready');
    for (final listener in _listeners.values) {
      _log('  ${listener.family == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
          'address: ${listener.publicAddress}');
    }
    _log('  Pubkey:   ${_identity.pubkeyHex}');
    _log('Waiting for connections...');
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _staleCleanupTimer?.cancel();
    _statsTimer?.cancel();
    for (final listener in _listeners.values) {
      await listener.connectionsSub?.cancel();
    }

    for (final conn in _peerConnections.values) {
      try {
        await conn.stream?.close();
      } catch (_) {}
    }
    _peerConnections.clear();

    for (final listener in _listeners.values) {
      listener.rawSocket.close();
      listener.multiplexer = null;
    }
    _listeners.clear();
    _log('Rendezvous server stopped');
  }

  // ===== Public Address Discovery =====

  Future<void> _bindListenersAndDiscoverAddresses() async {
    final specs = _listenerSpecs();
    if (bindMode == AnchorBindMode.dual &&
        specs.length > 1 &&
        specs[0].port == specs[1].port) {
      throw ArgumentError(
        'Dual-stack mode requires distinct IPv4 and IPv6 ports',
      );
    }

    for (final spec in specs) {
      final listener = await _tryBindListener(
        spec.family,
        spec.port,
        requireDiscoverablePublicAddress: bindMode == AnchorBindMode.auto &&
            spec.family == InternetAddressType.IPv6,
      );
      if (listener != null) {
        _listeners[spec.family] = listener;
        if (bindMode == AnchorBindMode.auto) break;
      }
    }

    if (_listeners.isEmpty) {
      throw StateError('Failed to bind a usable UDP socket');
    }
  }

  List<_ListenerSpec> _listenerSpecs() {
    switch (bindMode) {
      case AnchorBindMode.auto:
        return <_ListenerSpec>[
          _ListenerSpec(InternetAddressType.IPv6, ipv6Port),
          _ListenerSpec(InternetAddressType.IPv4, ipv4Port),
        ];
      case AnchorBindMode.dual:
        return <_ListenerSpec>[
          _ListenerSpec(InternetAddressType.IPv6, ipv6Port),
          _ListenerSpec(InternetAddressType.IPv4, ipv4Port),
        ];
      case AnchorBindMode.ipv6:
        return <_ListenerSpec>[
          _ListenerSpec(InternetAddressType.IPv6, ipv6Port),
        ];
      case AnchorBindMode.ipv4:
        return <_ListenerSpec>[
          _ListenerSpec(InternetAddressType.IPv4, ipv4Port),
        ];
    }
  }

  Future<_AnchorListener?> _tryBindListener(
    InternetAddressType family,
    int listenerPort, {
    bool requireDiscoverablePublicAddress = false,
  }) async {
    final bindAddress = family == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4;

    try {
      final socket = await RawDatagramSocket.bind(bindAddress, listenerPort);
      final publicAddress =
          await _discoverPublicAddressForFamily(family, listenerPort);

      if (requireDiscoverablePublicAddress && publicAddress == null) {
        _log('No usable public IPv6 address detected, falling back to IPv4');
        socket.close();
        return null;
      }

      return _AnchorListener(
        family: family,
        port: listenerPort,
        rawSocket: socket,
        publicAddress:
            publicAddress ?? _defaultBindAddressForFamily(family, listenerPort),
      );
    } catch (e) {
      _log('Failed to bind '
          '${family == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
          'socket on port $listenerPort: $e');
      return null;
    }
  }

  Future<String?> _discoverPublicAddressForFamily(
    InternetAddressType family,
    int listenerPort,
  ) async {
    final label = family == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';

    // IPv6: GCE assigns global addresses directly to the interface, so
    // NetworkInterface.list() works. For IPv4, GCE uses 1:1 NAT — the
    // interface only sees the RFC1918 internal address (e.g. 10.20.0.2),
    // so we must query an external source.
    if (family == InternetAddressType.IPv6) {
      try {
        final interfaces = await NetworkInterface.list(
          type: family,
          includeLoopback: false,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback || addr.isLinkLocal) continue;
            final discovered = _formatAddress(addr.address, listenerPort);
            _log('Discovered public $label address: $discovered');
            return discovered;
          }
        }
      } catch (e) {
        _log('Failed to enumerate $label interfaces: $e');
      }
    }

    // GCE metadata server — fast, no external dependency, works for both
    // families. IPv4 metadata returns the external NAT IP; IPv6 returns
    // the /96 prefix (we strip the trailing /96 if present).
    final metadataPath = family == InternetAddressType.IPv4
        ? 'network-interfaces/0/access-configs/0/external-ip'
        : 'network-interfaces/0/ipv6s';
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(
          'http://metadata.google.internal/computeMetadata/v1/instance/$metadataPath',
        ));
        request.headers.set('Metadata-Flavor', 'Google');
        final response = await request.close();
        if (response.statusCode == 200) {
          final body =
              await response.transform(const SystemEncoding().decoder).join();
          var ip = body.trim();
          // IPv6 metadata may return "addr/96" — strip the prefix length.
          if (ip.contains('/')) ip = ip.split('/').first;
          final parsed = InternetAddress.tryParse(ip);
          if (parsed != null && parsed.type == family) {
            final discovered = _formatAddress(parsed.address, listenerPort);
            _log('Discovered public $label address via GCE metadata: '
                '$discovered');
            return discovered;
          }
        }
      } finally {
        client.close();
      }
    } catch (e) {
      _log('GCE metadata unavailable for $label: $e');
    }

    // Fallback: external service.
    final url = family == InternetAddressType.IPv6
        ? 'https://ipv6.seeip.org'
        : 'https://api.seeip.org';
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body =
            await response.transform(const SystemEncoding().decoder).join();
        final ip = body.trim();
        final parsed = InternetAddress.tryParse(ip);
        if (parsed != null && parsed.type == family) {
          final discovered = _formatAddress(parsed.address, listenerPort);
          _log('Discovered public $label address via seeip.org: $discovered');
          return discovered;
        }
      } finally {
        client.close();
      }
    } catch (e) {
      _log('Failed to discover public $label address via seeip: $e');
    }

    return null;
  }

  String _defaultBindAddressForFamily(
    InternetAddressType family,
    int listenerPort,
  ) =>
      family == InternetAddressType.IPv6
          ? '[::]:$listenerPort'
          : '0.0.0.0:$listenerPort';

  String _formatAddress(String ip, int listenerPort) =>
      ip.contains(':') ? '[$ip]:$listenerPort' : '$ip:$listenerPort';

  // ===== Connection Handling =====

  void _handleIncomingConnection(_AnchorListener listener, UDPSocket socket) {
    final remoteAddr = '${socket.remoteAddress.address}:${socket.remotePort}';
    _log('Incoming UDX connection from $remoteAddr '
        'via ${listener.family == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
        'listener ${listener.port}');

    final knownPubkey = _addressToPubkey[remoteAddr];
    if (knownPubkey != null) {
      _log('Known peer $knownPubkey at $remoteAddr');
      socket.on('stream').listen((UDXEvent event) {
        final stream = event.data as UDXStream;
        _trackPeerConnection(
          pubkeyHex: knownPubkey,
          connection: _PeerConnection(
            pubkeyHex: knownPubkey,
            udpSocket: socket,
            stream: stream,
            addr: socket.remoteAddress,
            port: socket.remotePort,
            advertisedLocalAddress: listener.publicAddress,
            listenerFamily: listener.family,
          ),
        );
        _listenToStream(knownPubkey, stream);
      });
      socket.flushStreamBuffer();
      return;
    }

    // Unknown — use tempKey until ANNOUNCE reveals identity
    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      _handleIncomingStream(listener, socket, stream);
    });
    socket.flushStreamBuffer();
  }

  void _handleIncomingStream(
    _AnchorListener listener,
    UDPSocket socket,
    UDXStream stream,
  ) {
    final tempKey = '${socket.remoteAddress}:${socket.remotePort}:${stream.id}';

    _pendingIncoming[tempKey] = _PeerConnection(
      pubkeyHex: '',
      udpSocket: socket,
      stream: stream,
      addr: socket.remoteAddress,
      port: socket.remotePort,
      advertisedLocalAddress: listener.publicAddress,
      listenerFamily: listener.family,
    );

    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;
        final effectiveId = _tempKeyToPubkey[tempKey] ?? tempKey;
        _processIncomingData(effectiveId, data,
            observedIp: socket.remoteAddress.address,
            observedPort: socket.remotePort,
            observedFamily: socket.remoteAddress.type,
            localPublicAddress: listener.publicAddress);
      },
      onError: (e) {
        _log('UDX stream error from $tempKey: $e');
      },
      onDone: () {
        _log('UDX stream closed from $tempKey');
        final pubkeyHex = _tempKeyToPubkey.remove(tempKey);
        if (pubkeyHex != null) {
          final existing = _peerConnections[pubkeyHex];
          if (existing?.stream == stream) {
            _peerConnections.remove(pubkeyHex);
            _addressToPubkey
                .remove('${socket.remoteAddress.address}:${socket.remotePort}');
            _log('Peer disconnected: ${pubkeyHex.substring(0, 8)}...');
          }
        }
        _pendingIncoming.remove(tempKey);
      },
    );
  }

  void _listenToStream(String pubkeyHex, UDXStream stream) {
    final conn = _peerConnections[pubkeyHex];
    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;
        _processIncomingData(pubkeyHex, data,
            observedIp: conn?.addr.address,
            observedPort: conn?.port,
            observedFamily: conn?.addr.type,
            localPublicAddress: conn?.advertisedLocalAddress);
      },
      onError: (e) {
        _log('UDX stream error from $pubkeyHex: $e');
      },
      onDone: () {
        _log('UDX stream closed from ${pubkeyHex.substring(0, 8)}...');
        final existing = _peerConnections[pubkeyHex];
        if (existing?.stream == stream) {
          _peerConnections.remove(pubkeyHex);
          _addressToPubkey.remove('${existing!.addr.address}:${existing.port}');
        }
      },
    );
  }

  void _handleRawPacket(
    _AnchorListener listener,
    Uint8List data,
    InternetAddress address,
    int port,
  ) {
    // Skip punch packets
    if (data.length == 36 &&
        data[0] == 0x42 &&
        data[1] == 0x43 &&
        data[2] == 0x50 &&
        data[3] == 0x55) {
      return;
    }
    if (data.length < 50) return;

    _log('Raw UDP packet: ${data.length} bytes from ${address.address}:$port');
    _processIncomingData('${address.address}:$port', data,
        observedIp: address.address,
        observedPort: port,
        observedFamily: address.type,
        localPublicAddress: listener.publicAddress);
  }

  // ===== Packet Processing =====

  Future<void> _processIncomingData(
    String peerId,
    Uint8List data, {
    String? observedIp,
    int? observedPort,
    InternetAddressType? observedFamily,
    String? localPublicAddress,
  }) async {
    BitchatPacket packet;
    try {
      packet = BitchatPacket.deserialize(data);
    } catch (e) {
      _log('Failed to deserialize packet from $peerId: $e');
      return;
    }

    // Verify signature
    final isValid = await _protocol.verifyPacket(packet);
    if (!isValid) {
      _log('Dropping packet with invalid signature from $peerId');
      return;
    }

    final senderHex = _pubkeyToHex(packet.senderPubkey);

    // Map incoming connection to pubkey
    if (peerId.contains(':') && !_peerConnections.containsKey(senderHex)) {
      _tempKeyToPubkey[peerId] = senderHex;
      _mapIncomingConnectionToPubkey(peerId, senderHex);
    }

    switch (packet.type) {
      case PacketType.announce:
        _handleAnnounce(packet,
            observedIp: observedIp,
            observedPort: observedPort,
            localPublicAddress: localPublicAddress);
      case PacketType.signaling:
        _signalingHandler.processSignaling(
          packet.senderPubkey,
          packet.payload,
          observedIp: observedIp,
          observedPort: observedPort,
        );
      case PacketType.message:
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        // The rendezvous server never relays message content.
        _log('Dropping ${packet.type} from ${senderHex.substring(0, 8)}... '
            '(rendezvous server does not relay messages)');
      case PacketType.ack:
      case PacketType.nack:
      case PacketType.readReceipt:
        break;
    }
  }

  void _handleAnnounce(
    BitchatPacket packet, {
    String? observedIp,
    int? observedPort,
    String? localPublicAddress,
  }) {
    final data = _protocol.decodeAnnounce(packet.payload);
    final senderHex = data.pubkeyHex;

    _signalingHandler.processAnnounce(
      data,
      observedIp: observedIp,
      observedPort: observedPort,
    );

    _log('ANNOUNCE: ${data.nickname} (${senderHex.substring(0, 8)}...)');
    // Send our ANNOUNCE back so they know who we are
    _sendAnnounceTo(
      packet.senderPubkey,
      address: localPublicAddress,
    );
  }

  void _mapIncomingConnectionToPubkey(String tempKey, String pubkeyHex) {
    final pending = _pendingIncoming.remove(tempKey);
    if (pending != null) {
      _trackPeerConnection(
        pubkeyHex: pubkeyHex,
        connection: _PeerConnection(
          pubkeyHex: pubkeyHex,
          udpSocket: pending.udpSocket,
          stream: pending.stream,
          addr: pending.addr,
          port: pending.port,
          advertisedLocalAddress: pending.advertisedLocalAddress,
          listenerFamily: pending.listenerFamily,
        ),
      );
      _log('Mapped connection → ${pubkeyHex.substring(0, 8)}...');
    }
  }

  // ===== Sending =====

  Future<bool> _sendSignaling(
      Uint8List recipientPubkey, Uint8List signalingPayload) async {
    final packet = _protocol.createSignalingPacket(
      recipientPubkey: recipientPubkey,
      signalingPayload: signalingPayload,
    );
    await _protocol.signPacket(packet);
    return _sendPacket(_pubkeyToHex(recipientPubkey), packet);
  }

  Future<void> _sendAnnounceTo(
    Uint8List recipientPubkey, {
    String? address,
  }) async {
    final packet = _protocol.createAnnouncePacket(address: address);
    await _protocol.signPacket(packet);
    _sendPacket(_pubkeyToHex(recipientPubkey), packet);
  }

  Future<void> _broadcastAnnounce() async {
    if (_peerConnections.isEmpty) return;

    for (final entry in _peerConnections.entries) {
      try {
        final packet = _protocol.createAnnouncePacket(
          address: entry.value.advertisedLocalAddress,
        );
        await _protocol.signPacket(packet);
        await entry.value.stream?.add(packet.serialize());
      } catch (e) {
        _log('Failed to send ANNOUNCE to ${entry.key.substring(0, 8)}...: $e');
      }
    }
  }

  bool _sendPacket(String pubkeyHex, BitchatPacket packet) {
    final conn = _peerConnections[pubkeyHex];
    if (conn == null || conn.stream == null) {
      _log('Cannot send to ${pubkeyHex.substring(0, 8)}...: not connected');
      return false;
    }

    try {
      final data = packet.serialize();
      conn.stream!.add(data);
      return true;
    } catch (e) {
      _log('Failed to send to ${pubkeyHex.substring(0, 8)}...: $e');
      return false;
    }
  }

  void _trackPeerConnection({
    required String pubkeyHex,
    required _PeerConnection connection,
  }) {
    final existing = _peerConnections[pubkeyHex];
    if (existing != null &&
        (existing.addr.address != connection.addr.address ||
            existing.port != connection.port ||
            existing.listenerFamily != connection.listenerFamily)) {
      _addressToPubkey.remove('${existing.addr.address}:${existing.port}');
      unawaited(existing.stream?.close());
    }

    _peerConnections[pubkeyHex] = connection;
    _addressToPubkey['${connection.addr.address}:${connection.port}'] =
        pubkeyHex;
  }

  // ===== Stats =====

  void _printStats() {
    _log('--- Stats ---');
    _log('  Connected: ${_peerConnections.length} '
        '(verified: ${_peerTable.verifiedCount}, '
        'unverified: ${_peerTable.unverifiedCount})');
    _log('  Address table: ${_addressTable.length} entries');
    for (final peer in _peerTable.verifiedPeers) {
      final addresses = _addressTable.lookupAll(peer.pubkeyHex);
      final connected = _peerConnections.containsKey(peer.pubkeyHex);
      _log('  ${peer.nickname} (${peer.pubkeyHex.substring(0, 8)}...) '
          '${connected ? "LIVE" : "offline"}'
          '${addresses.isNotEmpty ? " addr=${addresses.map((entry) => "${entry.ip}:${entry.port}").join(",")}" : ""}');
    }
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[$ts] $message');
  }
}

class _PeerConnection {
  final String pubkeyHex;
  final UDPSocket udpSocket;
  final UDXStream? stream;
  final InternetAddress addr;
  final int port;
  final String? advertisedLocalAddress;
  final InternetAddressType listenerFamily;

  _PeerConnection({
    required this.pubkeyHex,
    required this.udpSocket,
    this.stream,
    required this.addr,
    required this.port,
    required this.advertisedLocalAddress,
    required this.listenerFamily,
  });
}

class _AnchorListener {
  final InternetAddressType family;
  final int port;
  final RawDatagramSocket rawSocket;
  final String publicAddress;
  UDXMultiplexer? multiplexer;
  StreamSubscription? connectionsSub;

  _AnchorListener({
    required this.family,
    required this.port,
    required this.rawSocket,
    required this.publicAddress,
  });
}

class _ListenerSpec {
  final InternetAddressType family;
  final int port;

  const _ListenerSpec(this.family, this.port);
}
