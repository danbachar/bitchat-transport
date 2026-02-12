import 'dart:async';
import 'dart:typed_data';
import 'package:bitchat_transport/bitchat_transport.dart' show Block;
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'dart:io';

import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../models/identity.dart';
import '../models/peer.dart';
import '../store/store.dart';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_udx/dart_udx.dart';
import 'package:http/http.dart' as http;

/// Default display info for LibP2P transport
const _defaultLibP2PDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'LibP2P peer-to-peer transport',
  color: Colors.green,
);

/// LibP2P configuration for the transport service
class LibP2PConfig {
  /// Listen addresses for the libp2p host
  final List<String> listenAddresses;

  /// Bootstrap peers to connect to initially
  final List<String> bootstrapPeers;

  /// Enable mDNS discovery for local network peers
  final bool enableMdns;

  /// Enable DHT for peer routing and discovery
  final bool enableDht;

  /// Enable relay for NAT traversal
  final bool enableRelay;

  const LibP2PConfig({
    this.listenAddresses = const ['/ip4/0.0.0.0/tcp/0'],
    this.bootstrapPeers = const [],
    this.enableMdns = true,
    this.enableDht = false,
    this.enableRelay = false,
  });
}

/// LibP2P-based transport service with embedded routing logic.
///
/// This is a direct peer-to-peer transport - NO forwarding/relaying of messages
/// for other peers. All messages go directly from sender to recipient.
///
/// Routing logic (ANNOUNCE handling, peer management) is embedded directly
/// in this service class, not in a separate router.
class LibP2PTransportService extends TransportService {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// LibP2P configuration
  final LibP2PConfig config;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol version
  static const int protocolVersion = 1;

  /// LibP2P host instance
  Host? _host;

  /// Get the host ID (PeerId) as string - null if host not initialized
  String? get hostId => _host?.id.toString();

  /// Get the host addresses (list of multiaddrs) - empty if host not initialized
  List<String> get hostAddrs =>
      _host?.addrs.map((a) => a.toString()).toList() ?? [];

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // ===== Application-level callbacks =====

  /// Called when an application message is received.
  /// Parameters: messageId, senderPubkey, payload
  void Function(String messageId, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;

  /// Called when a new peer connects (after ANNOUNCE)
  void Function(Peer peer)? onPeerConnected;

  /// Called when a peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;

  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;

  LibP2PTransportService({
    required this.identity,
    required this.store,
    this.config = const LibP2PConfig(),
  });

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.libp2p;

  @override
  TransportDisplayInfo get displayInfo => _defaultLibP2PDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  /// @deprecated Use PeerStore.discoveredLibp2pPeers instead - the PeerStore is the single source of truth
  @override
  Stream<TransportDiscoveryEvent> get discoveryStream => const Stream.empty();

  /// @deprecated Use PeerStore.libp2pPeers instead
  @override
  List<TransportPeer> get peers => [];

  /// @deprecated Use PeerStore.connectedPeers instead
  @override
  List<TransportPeer> get connectedPeers => [];

  @override
  int get connectedCount => connectedPeers.length;

  @override
  bool get isActive => _state == TransportState.active;

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('LibP2P transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing LibP2P transport service');

    try {
      _host = await createHost();
      _log.i('Host: ${_host!.id} ${_host!.addrs}');

      // DERP DERP
      // TODO: Initialize dart_libp2p host here
      // final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      // _host = await Libp2p.new_([...options...]);

      // Sample Output : "2a05:dfc7:5::53"

      _setState(TransportState.ready);
      _log.i('LibP2P transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize LibP2P transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start LibP2P transport in state: $_state');
      return;
    }

    _log.i('Starting LibP2P transport');

    try {
      // TODO: Start libp2p host - await _host?.start();
      _setState(TransportState.active);
      _log.i('LibP2P transport started');
    } catch (e) {
      _log.e('Failed to start LibP2P transport: $e');
      _setState(TransportState.error);
    }
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping LibP2P transport');

    try {
      // TODO: Stop libp2p host - await _host?.stop();
      if (_state == TransportState.active) {
        _setState(TransportState.ready);
      }
      _log.i('LibP2P transport stopped');
    } catch (e) {
      _log.e('Failed to stop LibP2P transport: $e');
    }
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    _log.d('Connecting to peer: $peerId');
    try {
      // TODO: Use dart_libp2p to connect
      // await _host?.connect(AddrInfo(peerId, addresses));
      return true;
    } catch (e) {
      _log.e('Failed to connect to peer $peerId: $e');
      return false;
    }
  }

  /// Connect to a peer using their host info (ID and addresses)
  /// This is used when accepting a friend request or receiving acceptance
  /// Returns the successful address on success, null on failure
  Future<String?> connectToHost(
      {required String hostId, required List<String> hostAddrs}) async {
    if (_host == null) {
      _log.w('Cannot connect: host not initialized');
      return null;
    }

    _log.i('Connecting to host: $hostId with addresses: $hostAddrs');

    // Separate IPv4 and IPv6 addresses - try IPv4 first (more common/reliable)
    final ipv4Addrs =
        hostAddrs.where((addr) => addr.startsWith('/ip4/')).toList();
    final ipv6Addrs =
        hostAddrs.where((addr) => addr.startsWith('/ip6/')).toList();

    // Try IPv4 first, then IPv6
    final orderedAddrs = [...ipv4Addrs, ...ipv6Addrs];

    if (orderedAddrs.isEmpty) {
      _log.w('No valid addresses found for host $hostId');
      return null;
    }

    _log.d(
        'Trying ${ipv4Addrs.length} IPv4 and ${ipv6Addrs.length} IPv6 addresses');

    for (final addr in orderedAddrs) {
      try {
        _log.i('Connecting to host: $hostId with address: $addr');
        final peerId = PeerId.fromString(hostId);
        final address = MultiAddr(addr);
        final addrs = [address];
        final addrInfo = AddrInfo(peerId, addrs);
        await _host!.connect(addrInfo);
        _log.i('Successfully connected to host: $hostId with address: $addr');
        return addr;
      } catch (e) {
        _log.e('Failed to connect to host $hostId with address: $addr: $e');
      }
    }

    return null;
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');
    try {
      // TODO: Use dart_libp2p to disconnect
      _connectionController.add(TransportConnectionEvent(
        peerId: peerId,
        transport: TransportType.libp2p,
        connected: false,
        reason: 'Disconnected by request',
      ));
    } catch (e) {
      _log.e('Failed to disconnect from peer $peerId: $e');
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    try {
      const duration = Duration(seconds: 10);
      final ctx = Context(timeout: duration);
      P2PStream myStream = await _host!
          .newStream(PeerId.fromString(peerId), ['/gever/1.0.0'], ctx);
      await myStream.write(data);
      await myStream.close();

      _log.d('Sent ${data.length} bytes to peer $peerId');
      return true;
    } catch (e) {
      _log.e('Failed to send to peer $peerId: $e');
      return false;
    }
  }

  @override
  Future<void> broadcast(Uint8List data, {String? excludePeerId}) async {
    for (final peer in connectedPeers) {
      if (peer.peerId != excludePeerId) {
        await sendToPeer(peer.peerId, data);
      }
    }
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // No-op: Redux store is the source of truth for peer associations
    // The association is made via PeerAnnounceReceivedAction or FriendEstablishedAction
    _log.d('associatePeerWithPubkey called (no-op, using Redux store)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // Look up in Redux store
    final peer = store.state.peers.getPeerByPubkey(pubkey);
    return peer?.libp2pHostId;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // Look up in Redux store - find peer with matching libp2pHostId
    for (final peer in store.state.peers.peersList) {
      if (peer.libp2pHostId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing LibP2P transport');
    await stop();
    _host = null;
    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    _setState(TransportState.disposed);
  }

  // ===== Messaging API (same as BleTransportService) =====

  /// Send a message directly to a peer by pubkey.
  /// Returns true if sent successfully.
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    required String messageId,
  }) async {
    if (_host == null) {
      _log.w('Cannot send: host not initialized');
      return false;
    }

    // Look up peer in Redux store
    final peer = store.state.peers.getPeerByPubkey(recipientPubkey);
    if (peer == null) {
      _log.w('No peer found for pubkey');
      return false;
    }

    final hostId = peer.libp2pHostId;
    final hostAddrs = peer.libp2pHostAddrs;

    if (hostId == null || hostId.isEmpty) {
      _log.w('Peer has no libp2p host ID');
      return false;
    }

    // Ensure addresses are in peerstore before dialing
    if (hostAddrs != null && hostAddrs.isNotEmpty) {
      await _ensureAddressesInPeerstore(hostId, hostAddrs);
    }

    // Create message envelope with ID and send
    final envelope = _createMessageEnvelope(payload, messageId: messageId);
    return await sendToPeer(hostId, envelope);
  }

  /// Ensure peer addresses are in the libp2p peerstore
  Future<void> _ensureAddressesInPeerstore(
      String hostId, List<String> hostAddrs) async {
    if (_host == null) return;

    try {
      final peerId = PeerId.fromString(hostId);
      final multiAddrs = hostAddrs
          .map((addr) {
            try {
              return MultiAddr(addr);
            } catch (e) {
              _log.w('Invalid multiaddr: $addr');
              return null;
            }
          })
          .whereType<MultiAddr>()
          .toList();

      if (multiAddrs.isNotEmpty) {
        await _host!.peerStore.addrBook
            .addAddrs(peerId, multiAddrs, const Duration(hours: 1));
        _log.d('Added ${multiAddrs.length} addresses to peerstore for $hostId');
      }
    } catch (e) {
      _log.w('Failed to add addresses to peerstore: $e');
    }
  }

  /// Broadcast a message to all connected peers
  Future<void> broadcastMessage({required Uint8List payload}) async {
    // Generate a message ID for broadcast (same ID for all recipients)
    final messageId = const Uuid().v4().substring(0, 8);
    final envelope = _createMessageEnvelope(payload, messageId: messageId);
    await broadcast(envelope);
  }

  /// Send our ANNOUNCE to all connected peers
  Future<void> sendAnnounce() async {
    final payload = createAnnouncePayload();
    await broadcast(payload);
  }

  /// Create ANNOUNCE payload using envelope format
  ///
  /// Envelope: [type(1) + messageId(8) + pubkey(32)]
  /// Payload:  [version(2) + nickLen(1) + nick + addrLen(2) + addr]
  ///
  /// The address field is only populated when sending to friends.
  /// For non-friends or broadcast, addrLen is 0.
  Uint8List createAnnouncePayload({String? address}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final addressBytes = address != null ? Uint8List.fromList(address.codeUnits) : Uint8List(0);
    final buffer = BytesBuilder();

    // Type byte (1 byte)
    buffer.addByte(_msgTypeAnnounce);

    // MessageId (8 bytes) - zeros for ANNOUNCE
    buffer.add(Uint8List(8));

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Payload: version + nickname + address
    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    // Address length (2 bytes) + address
    final addrLenBytes = ByteData(2);
    addrLenBytes.setUint16(0, addressBytes.length, Endian.big);
    buffer.add(addrLenBytes.buffer.asUint8List());
    if (addressBytes.isNotEmpty) {
      buffer.add(addressBytes);
    }

    return buffer.toBytes();
  }

  // ===== Packet Processing =====

  /// Callback for ACK received (message delivered to recipient)
  void Function(String messageId)? onAckReceived;

  /// Callback for read receipt received (message read by recipient)
  void Function(String messageId)? onReadReceiptReceived;

  /// Process incoming data from a peer
  void onDataReceived(String peerId, Uint8List data, {int rssi = 0}) {
    _log.d('Data received from peer $peerId: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      data: data,
    ));

    if (data.isEmpty) {
      _log.w('Received empty data from peer');
      return;
    }

    // All messages use the same envelope format - handle uniformly
    _tryHandleEnvelope(peerId, data);
  }

  /// Handle all envelope messages (ANNOUNCE, MESSAGE, ACK, READ_RECEIPT).
  /// Format: [type(1) + messageId(8) + pubkey(32) + payload?]
  void _tryHandleEnvelope(String peerId, Uint8List data) {
    // Minimum envelope size: 1 (type) + 8 (msgId) + 32 (pubkey) = 41 bytes
    if (data.length < 41) {
      _log.w('Envelope too short: ${data.length} bytes');
      return;
    }

    final msgType = data[0];
    final messageId = String.fromCharCodes(data.sublist(1, 9));
    final senderPubkey = Uint8List.fromList(data.sublist(9, 41));
    final payload = data.length > 41 ? data.sublist(41) : Uint8List(0);

    switch (msgType) {
      case _msgTypeAnnounce:
        _handleAnnouncePayload(peerId, senderPubkey, payload);
        _log.d("libp2p: Received ANNOUNCE from peer");
      case _msgTypeMessage:
        _log.d('libp2p: Received message $messageId from peer');
        onMessageReceived?.call(messageId, senderPubkey, payload);
        // Send ACK back to sender
        _sendAckToPeer(peerId, messageId);

      case _msgTypeAck:
        _log.d('libp2p: Received ACK for message $messageId');
        onAckReceived?.call(messageId);

      case _msgTypeReadReceipt:
        _log.d('libp2p: Received read receipt for message $messageId');
        onReadReceiptReceived?.call(messageId);

      default:
        _log.w('libp2p: Unknown message type: 0x${msgType.toRadixString(16)}');
    }
  }

  /// Send ACK back to sender
  Future<void> _sendAckToPeer(String peerId, String messageId) async {
    final envelope = _createAckEnvelope(messageId);
    await sendToPeer(peerId, envelope);
  }

  /// Send a read receipt for a message
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List recipientPubkey,
  }) async {
    if (_host == null) {
      _log.w('Cannot send read receipt: host not initialized');
      return false;
    }

    final peer = store.state.peers.getPeerByPubkey(recipientPubkey);
    if (peer == null) {
      _log.w('No peer found for pubkey');
      return false;
    }

    final hostId = peer.libp2pHostId;
    if (hostId == null || hostId.isEmpty) {
      _log.w('Peer has no libp2p host ID');
      return false;
    }

    final envelope = _createReadReceiptEnvelope(messageId);
    return await sendToPeer(hostId, envelope);
  }

  /// Handle ANNOUNCE payload (after envelope parsing)
  ///
  /// Payload format: [version(2) + nickLen(1) + nick + addrLen(2) + addr]
  void _handleAnnouncePayload(String peerId, Uint8List senderPubkey, Uint8List payload) {
    // Minimum payload: version(2) + nickLen(1) = 3 bytes
    if (payload.length < 3) {
      _log.w('ANNOUNCE payload too short: ${payload.length} bytes');
      return;
    }

    var offset = 0;

    // Version (2 bytes)
    final version = ByteData.view(payload.buffer, payload.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    // Nickname length (1 byte) + nickname
    final nicknameLength = payload[offset];
    offset += 1;

    if (payload.length < offset + nicknameLength) {
      _log.w('ANNOUNCE payload too short for nickname');
      return;
    }

    final nickname = String.fromCharCodes(payload.sublist(offset, offset + nicknameLength));
    offset += nicknameLength;

    // Address length (2 bytes) + address (optional - may not exist in old payloads)
    String? address;
    if (offset + 2 <= payload.length) {
      final addrLength = ByteData.view(payload.buffer, payload.offsetInBytes + offset, 2)
          .getUint16(0, Endian.big);
      offset += 2;
      if (addrLength > 0 && offset + addrLength <= payload.length) {
        address = String.fromCharCodes(payload.sublist(offset, offset + addrLength));
      }
    }

    // Check if peer already exists in Redux store
    final existingPeer = store.state.peers.getPeerByPubkey(senderPubkey);
    final isNew = existingPeer == null;

    // Update Redux store via ANNOUNCE action
    // Use the address from payload if provided, otherwise use peerId as fallback
    store.dispatch(PeerAnnounceReceivedAction(
      publicKey: senderPubkey,
      nickname: nickname,
      protocolVersion: version,
      rssi: 0,
      transport: PeerTransport.libp2p,
      libp2pAddress: address ?? peerId,
    ));

    _log.i('Peer ${isNew ? "connected" : "updated"}: $nickname${address != null ? " (addr: $address)" : ""}');
  }

  /// Called when a peer connects at the transport level
  void onPeerTransportConnected(String peerId) {
    _log.d('Transport peer connected: $peerId');

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: true,
    ));
  }

  /// Called when a peer disconnects at the transport level
  void onPeerTransportDisconnected(String peerId) {
    final pubkey = getPubkeyForPeerId(peerId);
    if (pubkey != null) {
      final peerState = store.state.peers.getPeerByPubkey(pubkey);
      if (peerState != null) {
        store.dispatch(PeerLibp2pDisconnectedAction(pubkey));
        _log.i('Peer disconnected: ${peerState.displayName}');
      }
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: false,
    ));
  }

  // ===== Helper Methods =====

  /// Libp2p message types
  static const int _msgTypeAnnounce = 0x00;
  static const int _msgTypeMessage = 0x01;
  static const int _msgTypeAck = 0x02;
  static const int _msgTypeReadReceipt = 0x03;

  /// Create message envelope with ID for tracking.
  /// Format:
  /// [0]      : Message type (1 byte)
  /// [1-8]    : Message ID (8 bytes, short UUID as ASCII)
  /// [9-40]   : Sender pubkey (32 bytes)
  /// [41-N]   : Payload
  Uint8List _createMessageEnvelope(Uint8List payload,
      {required String messageId}) {
    final buffer = BytesBuilder();
    buffer.addByte(_msgTypeMessage);
    buffer.add(Uint8List.fromList(messageId.codeUnits)); // 8 bytes
    buffer.add(identity.publicKey); // 32 bytes
    buffer.add(payload);
    return buffer.toBytes();
  }

  /// Create ACK envelope for delivery confirmation.
  Uint8List _createAckEnvelope(String messageId) {
    final buffer = BytesBuilder();
    buffer.addByte(_msgTypeAck);
    buffer.add(Uint8List.fromList(messageId.codeUnits)); // 8 bytes
    buffer.add(identity.publicKey); // 32 bytes
    return buffer.toBytes();
  }

  /// Create read receipt envelope.
  Uint8List _createReadReceiptEnvelope(String messageId) {
    final buffer = BytesBuilder();
    buffer.addByte(_msgTypeReadReceipt);
    buffer.add(Uint8List.fromList(messageId.codeUnits)); // 8 bytes
    buffer.add(identity.publicKey); // 32 bytes
    return buffer.toBytes();
  }

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  Future<String> _getIPv6Address() async {
    // final response = await http.get(Uri.parse('https://api64.ipify.org/?format=text'));
    final response = await http.get(Uri.parse('https://ipv6.icanhazip.com/'));

    if (response.statusCode == 200) {
      return response.body.trim();
    } else {
      _log.w(
          'Failed to get IPv6 address from api64.ipify.org, status code: ${response.statusCode}');
      return '::1'; // Fallback to loopback
    }
  }

  Future<Host> createHost() async {
    final keyPair = await crypto_ed25519.generateEd25519KeyPair();
    final udx = UDX();
    final connMgr = p2p_conn_manager.ConnectionManager();

    String ipv6 = await _getIPv6Address();
    _log.i('Public IPv6 address: $ipv6');

    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      p2p_config.Libp2p.transport(
          UDXTransport(connManager: connMgr, udxInstance: udx)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      // Listen on both IPv4 and IPv6 for maximum connectivity
      p2p_config.Libp2p.listenAddrs([
        // MultiAddr('/ip4/0.0.0.0/udp/0/udx'),
        MultiAddr('/ip6/::/udp/0/udx'),
      ]),
    ];

    final host = await p2p_config.Libp2p.new_(options);
    host.setStreamHandler('/gever/1.0.0', _handleGeverRequest);
    await host.start();

    _log.i("Host has ${host.addrs.length} addresses");
    for (var addr in host.addrs) {
      _log.i('Listening on address: $addr');
    }
    return host;
  }

  // Helper function to truncate peer IDs for display
  String _truncatePeerId(PeerId peerId) {
    final peerIdStr = peerId.toBase58();
    final strLen = peerIdStr.length;
    return peerIdStr.substring(strLen - 8, strLen);
  }

  Future<void> _handleGeverRequest(P2PStream stream, PeerId remotePeer) async {
    try {
      // Read the message from the stream
      final data = await stream.read();
      if (data.isNotEmpty) {
        debugPrint(
            '📨 [GEVER] Received ${data.length} bytes from peer ${_truncatePeerId(remotePeer)}');

        // Pass to onDataReceived which handles envelope parsing
        onDataReceived(remotePeer.toBase58(), Uint8List.fromList(data));
      }
    } catch (e) {
      _log.e('❌ [GEVER] Error reading from stream: $e');
    } finally {
      await stream.close();
    }
  }
}
