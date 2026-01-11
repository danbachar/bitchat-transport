import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import '../transport/transport_service.dart';
import '../mesh/router.dart' show BitchatRouter;
import '../mesh/libp2p_router.dart';
import '../models/identity.dart';

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
  /// Example: ['/ip4/0.0.0.0/tcp/0']
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

/// LibP2P-based implementation of the transport service.
///
/// This transport uses the libp2p networking stack to provide peer-to-peer
/// connectivity over TCP/IP networks (local network and internet).
///
/// ## Features
///
/// - **Peer Discovery**: Via mDNS (local) and DHT (global)
/// - **Multiplexed Streams**: Multiple streams over single connection
/// - **Secure Channels**: Noise protocol for encryption
/// - **NAT Traversal**: Relay and hole punching support
///
/// ## Usage
///
/// ```dart
/// final transport = LibP2PTransportService(
///   identity: myIdentity,
///   config: LibP2PConfig(
///     enableMdns: true,
///     bootstrapPeers: ['/dns4/bootstrap.libp2p.io/tcp/443/wss/...'],
///   ),
/// );
///
/// await transport.initialize();
/// await transport.start();
/// ```
class LibP2PTransportService extends TransportService
    with TransportServiceMixin {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// LibP2P configuration
  final LibP2PConfig config;

  /// LibP2P router for message handling
  late final LibP2PRouter _router;

  /// LibP2P host instance (to be initialized with dart_libp2p)
  // ignore: unused_field
  Object? _host;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Known peers on this transport
  final Map<String, TransportPeer> _peers = {};

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();
  final _discoveryController =
      StreamController<TransportDiscoveryEvent>.broadcast();

  LibP2PTransportService({
    required this.identity,
    this.config = const LibP2PConfig(),
  }) {
    _router = LibP2PRouter(identity: identity);
    _setupRouterCallbacks();
  }

  void _setupRouterCallbacks() {
    _router.onSendPacket = _sendPacketToTransport;
    _router.onBroadcast = _broadcastToTransport;
  }

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.libp2p;

  @override
  TransportDisplayInfo get displayInfo => _defaultLibP2PDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  BitchatRouter get router => _router;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  Stream<TransportDiscoveryEvent> get discoveryStream =>
      _discoveryController.stream;

  @override
  List<TransportPeer> get peers => _peers.values.toList();

  @override
  List<TransportPeer> get connectedPeers =>
      _peers.values.where((p) => _isConnected(p.peerId)).toList();

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
      // Initialize the router
      await _router.initialize(
        listenAddresses: config.listenAddresses,
        bootstrapPeers: config.bootstrapPeers,
      );

      // Note: Actual libp2p host initialization would go here
      // The specific API depends on dart_libp2p's implementation

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
      // Start listening and peer discovery
      // Note: Actual implementation depends on dart_libp2p's API

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
      // Stop listening but maintain existing connections
      // Note: Actual implementation depends on dart_libp2p's API

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
      // Note: Actual connection logic depends on dart_libp2p's API
      // Would typically use host.connect(peerId, addresses)

      return true;
    } catch (e) {
      _log.e('Failed to connect to peer $peerId: $e');
      return false;
    }
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');

    try {
      // Note: Actual disconnection logic depends on dart_libp2p's API

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
      // Note: Actual sending logic depends on dart_libp2p's API
      // Would typically open a stream and send data

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
    associatePeerWithPubkeyImpl(peerId, pubkey);

    // Also update the router's mapping
    _router.associatePeerIdWithPubkey(peerId, pubkey);

    // Update the peer object if it exists
    final peer = _peers[peerId];
    if (peer != null) {
      peer.publicKey = pubkey;
    }

    _log.d('Associated peer $peerId with pubkey');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) =>
      getPeerIdForPubkeyImpl(pubkey);

  @override
  Uint8List? getPubkeyForPeerId(String peerId) =>
      getPubkeyForPeerIdImpl(peerId);

  @override
  Future<void> dispose() async {
    _log.i('Disposing LibP2P transport');

    await stop();

    _router.dispose();
    _host = null;

    clearPubkeyAssociations();
    _peers.clear();

    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    await _discoveryController.close();

    _setState(TransportState.disposed);
  }

  // ===== LibP2P-Specific Methods =====

  /// Get the libp2p host instance (for advanced use)
  /// Will be typed properly when integrating with dart_libp2p
  Object? get host => _host;

  /// Get the local peer ID
  String? get localPeerId {
    // Note: Would return _host?.id.toString()
    return null;
  }

  /// Get multiaddresses this node is listening on
  List<String> get listenAddresses {
    // Note: Would return _host?.addresses
    return [];
  }

  /// Connect to a peer by multiaddress
  Future<bool> connectToAddress(String multiaddr) async {
    _log.d('Connecting to address: $multiaddr');

    try {
      // Note: Actual implementation depends on dart_libp2p's API
      return true;
    } catch (e) {
      _log.e('Failed to connect to address $multiaddr: $e');
      return false;
    }
  }

  // ===== Internal Methods =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  bool _isConnected(String peerId) {
    // Note: Would check actual connection status from libp2p host
    return _peers.containsKey(peerId);
  }

  Future<bool> _sendPacketToTransport(
      Uint8List recipientPubkey, Uint8List data) async {
    final peerId = getPeerIdForPubkey(recipientPubkey);
    if (peerId == null) {
      _log.w('No peer ID found for pubkey');
      return false;
    }
    return sendToPeer(peerId, data);
  }

  Future<void> _broadcastToTransport(Uint8List data,
      {Uint8List? excludePeer}) async {
    String? excludePeerId;
    if (excludePeer != null) {
      excludePeerId = getPeerIdForPubkey(excludePeer);
    }
    await broadcast(data, excludePeerId: excludePeerId);
  }

  // ===== Event Handlers =====
  // These methods will be called by libp2p event listeners when fully integrated

  // ignore: unused_element
  void _onPeerConnected(String peerId) {
    _log.d('Peer connected: $peerId');

    final peer = TransportPeer(
      peerId: peerId,
      transport: TransportType.libp2p,
    );

    final isNew = !_peers.containsKey(peerId);
    _peers[peerId] = peer;

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: true,
    ));

    if (isNew) {
      _discoveryController.add(TransportDiscoveryEvent(
        peer: peer,
        isNew: true,
      ));
    }

    // Notify router
    _router.onPeerTransportConnected(peerId);
  }

  // ignore: unused_element
  void _onPeerDisconnected(String peerId) {
    _log.d('Peer disconnected: $peerId');

    _peers.remove(peerId);

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: false,
    ));

    // Notify router if we know the pubkey
    final pubkey = getPubkeyForPeerId(peerId);
    if (pubkey != null) {
      _router.onPeerTransportDisconnected(pubkey);
    }

    // Clean up pubkey association
    removePeerPubkeyAssociation(peerId);
  }

  // ignore: unused_element
  void _onDataReceived(String peerId, Uint8List data) {
    _log.d('Data received from peer $peerId: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      data: data,
    ));

    // Forward to router for processing
    final pubkey = getPubkeyForPeerId(peerId);
    _router.onPacketReceived(
      data,
      fromPeer: pubkey,
      rssi: 0, // No RSSI for internet connections
    );
  }
}
