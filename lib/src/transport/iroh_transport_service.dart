import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../models/identity.dart';
import '../protocol/protocol_handler.dart';
import '../store/store.dart';
import '../iroh/iroh_node.dart';

/// Default display info for iroh transport
const _defaultIrohDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'Iroh peer-to-peer transport',
  color: Colors.green,
);

/// Iroh configuration for the transport service
class IrohConfig {
  /// Relay server URLs for NAT traversal.
  /// Iroh uses relay servers to ensure all peers are always reachable.
  /// Connections start through relay and migrate to direct when possible.
  final List<String> relayUrls;

  /// ALPN protocol identifier for bitchat
  final String alpn;

  /// Default relay servers (iroh's public relay infrastructure)
  static const defaultRelayUrls = [
    'https://use1-1.relay.iroh.network.',
    'https://euw1-1.relay.iroh.network.',
  ];

  const IrohConfig({
    this.relayUrls = defaultRelayUrls,
    this.alpn = 'bitchat/1',
  });
}

/// Iroh-based transport service.
///
/// Uses iroh for peer-to-peer connectivity with automatic NAT traversal.
/// - NodeId IS the Ed25519 public key (no separate PeerId mapping)
/// - Built-in relay + hole punching (no STUN/NAT config needed)
/// - QUIC-based with automatic encryption
/// - Simpler addressing: just NodeId + optional relay URL
///
/// This is a direct peer-to-peer transport - NO forwarding/relaying of messages
/// for other peers. All messages go directly from sender to recipient.
class IrohTransportService extends TransportService {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// Iroh configuration
  final IrohConfig config;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol handler for encoding/decoding
  final ProtocolHandler protocolHandler;

  /// Iroh endpoint instance (null until initialized)
  IrohEndpoint? _endpoint;

  /// Factory for creating iroh endpoints (injected for testability)
  final IrohEndpointFactory? endpointFactory;

  /// Subscription for connection events
  StreamSubscription<IrohConnectionEvent>? _connectionEventSub;

  /// Subscription for accepting incoming connections
  StreamSubscription<void>? _acceptLoopSub;

  /// Get our NodeId as hex string - null if endpoint not initialized.
  /// In iroh, the NodeId is derived from the same Ed25519 key,
  /// so this should match identity.publicKey.
  String? get nodeIdHex => _endpoint?.nodeId.toHex();

  /// Get the relay URL we're using, if any
  String? get relayUrl => _endpoint?.relayUrl;

  /// Get our direct addresses (IP:port pairs)
  List<String> get directAddresses => _endpoint?.directAddresses ?? [];

  /// Get our NodeAddr for sharing with other peers.
  /// Contains NodeId + relay URL + direct addresses.
  NodeAddr? get nodeAddr => _endpoint?.nodeAddr;

  /// Get shareable addresses for ANNOUNCE packets.
  ///
  /// Returns a list of address strings in priority order.
  /// Format: relay URL first (if available), then direct addresses.
  List<String> getShareableAddresses() {
    final addr = nodeAddr;
    if (addr == null) return [];

    final addresses = <String>[];
    if (addr.relayUrl != null) {
      addresses.add(addr.relayUrl!);
    }
    addresses.addAll(addr.directAddresses);
    return addresses;
  }

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====

  /// Called when iroh data is received and ready for routing.
  /// The coordinator deserializes as BitchatPacket and routes via MessageRouter.processPacket().
  void Function(String nodeIdHex, Uint8List data)? onIrohDataReceived;

  IrohTransportService({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    this.config = const IrohConfig(),
    this.endpointFactory,
  });

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.iroh;

  @override
  TransportDisplayInfo get displayInfo => _defaultIrohDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => store.state.peers.irohPeers.length;

  @override
  bool get isActive => _state == TransportState.active;

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('Iroh transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing iroh transport service');

    try {
      if (endpointFactory != null) {
        _endpoint = await endpointFactory!.create(
          secretKey: identity.privateKey,
          relayUrls: config.relayUrls,
          alpns: [config.alpn],
        );

        _log.i('Iroh endpoint created: NodeId=${_endpoint!.nodeId}');
        _log.i('Relay URL: ${_endpoint!.relayUrl}');
        _log.i('Direct addresses: ${_endpoint!.directAddresses}');

        // Listen for connection events
        _connectionEventSub =
            _endpoint!.connectionEvents.listen(_onConnectionEvent);

        // Start accept loop for incoming connections
        _startAcceptLoop();
      } else {
        _log.w('No IrohEndpointFactory provided — iroh transport will be '
            'non-functional until native bindings are available');
      }

      _setState(TransportState.ready);
      _log.i('Iroh transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize iroh transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start iroh transport in state: $_state');
      return;
    }

    _log.i('Starting iroh transport');
    _setState(TransportState.active);
    _log.i('Iroh transport started');
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping iroh transport');

    try {
      if (_state == TransportState.active) {
        _setState(TransportState.ready);
      }

      _connectionEventSub?.cancel();
      _connectionEventSub = null;
      _acceptLoopSub?.cancel();
      _acceptLoopSub = null;

      if (_endpoint != null) {
        await _endpoint!.close();
      }
      _log.i('Iroh transport stopped');
    } catch (e) {
      _log.e('Failed to stop iroh transport: $e');
    }
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    _log.d('Connecting to peer: $peerId');
    try {
      // Look up peer's NodeAddr from store
      final peer = _findPeerByNodeIdHex(peerId);
      if (peer == null) {
        _log.w('No peer found with nodeId: $peerId');
        return false;
      }

      return await connectToNode(
        nodeIdHex: peerId,
        relayUrl: peer.irohRelayUrl,
        directAddresses: peer.irohDirectAddresses ?? [],
      ) != null;
    } catch (e) {
      _log.e('Failed to connect to peer $peerId: $e');
      return false;
    }
  }

  /// Connect to a peer using their iroh addressing info.
  /// Returns the connection method description on success, null on failure.
  Future<String?> connectToNode({
    required String nodeIdHex,
    String? relayUrl,
    List<String> directAddresses = const [],
  }) async {
    if (_endpoint == null) {
      _log.w('Cannot connect: endpoint not initialized');
      return null;
    }

    _log.i('connectToNode: ${nodeIdHex.substring(0, 16)}... '
        'relay: $relayUrl, ${directAddresses.length} direct addrs');

    try {
      final nodeId = NodeId.fromHex(nodeIdHex);
      final addr = NodeAddr(
        nodeId: nodeId,
        relayUrl: relayUrl,
        directAddresses: directAddresses,
      );

      final conn = await _endpoint!.connect(addr, alpn: config.alpn);
      _log.i('connectToNode: connected to ${nodeIdHex.substring(0, 16)}...');

      // The connection is now managed by iroh — it handles keepalive,
      // migration between relay and direct, etc.
      await conn.close(); // We use one-shot streams, not persistent connections

      final method = relayUrl != null ? 'relay:$relayUrl' : 'direct';
      return method;
    } catch (e) {
      _log.e('connectToNode failed: $e');
      return null;
    }
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');
    // In iroh, connections are managed automatically.
    // We just emit the disconnect event and let the store handle cleanup.
    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.iroh,
      connected: false,
      reason: 'Disconnected by request',
    ));
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    if (_endpoint == null) {
      _log.e('Cannot send: endpoint not initialized');
      return false;
    }

    try {
      // Look up peer's addressing info from store
      final peer = _findPeerByNodeIdHex(peerId);
      final nodeId = NodeId.fromHex(peerId);
      final addr = NodeAddr(
        nodeId: nodeId,
        relayUrl: peer?.irohRelayUrl,
        directAddresses: peer?.irohDirectAddresses ?? [],
      );

      final conn = await _endpoint!.connect(addr, alpn: config.alpn);
      final stream = await conn.openBi();
      await stream.write(data);
      await stream.close();
      await conn.close();

      _log.d('Sent ${data.length} bytes to peer ${peerId.substring(0, 16)}...');
      return true;
    } catch (e) {
      _log.e('Failed to send to peer $peerId: $e');
      return false;
    }
  }

  @override
  Future<void> broadcast(
    Uint8List data, {
    Uint8List? friendData,
    Set<String>? friendDeviceIds,
  }) async {
    for (final peer in store.state.peers.irohPeers) {
      final nodeIdHex = peer.irohNodeIdHex;
      if (nodeIdHex != null) {
        await sendToPeer(nodeIdHex, data);
      }
    }
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // In iroh, NodeId IS the pubkey — no mapping needed.
    // The association is implicit.
    _log.d('associatePeerWithPubkey called (no-op — iroh NodeId is pubkey)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // In iroh, the peer ID is the pubkey hex
    return pubkey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // In iroh, the peer ID is the pubkey hex
    try {
      return NodeId.fromHex(peerId).publicKey;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing iroh transport');
    await stop();
    _endpoint = null;
    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    _setState(TransportState.disposed);
  }

  // ===== Packet Processing =====

  /// Process incoming data from a peer.
  ///
  /// Forwards raw bytes to the coordinator via [onIrohDataReceived].
  /// The coordinator deserializes as BitchatPacket and routes to MessageRouter.
  void onDataReceived(String nodeIdHex, Uint8List data, {int rssi = 0}) {
    _log.d('Data received from peer $nodeIdHex: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: nodeIdHex,
      transport: TransportType.iroh,
      data: data,
    ));

    if (data.isEmpty) {
      _log.w('Received empty data from peer');
      return;
    }

    // Forward to coordinator for deserialization and routing
    onIrohDataReceived?.call(nodeIdHex, data);
  }

  /// Called when a peer connects at the transport level
  void onPeerTransportConnected(String nodeIdHex) {
    _log.d('Transport peer connected: $nodeIdHex');

    _connectionController.add(TransportConnectionEvent(
      peerId: nodeIdHex,
      transport: TransportType.iroh,
      connected: true,
    ));
  }

  /// Called when a peer disconnects at the transport level
  void onPeerTransportDisconnected(String nodeIdHex) {
    final pubkey = getPubkeyForPeerId(nodeIdHex);
    if (pubkey != null) {
      final peerState = store.state.peers.getPeerByPubkey(pubkey);
      if (peerState != null) {
        store.dispatch(PeerIrohDisconnectedAction(pubkey));
        _log.i('Peer disconnected: ${peerState.displayName}');
      }
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: nodeIdHex,
      transport: TransportType.iroh,
      connected: false,
    ));
  }

  // ===== Connection Event Handling =====

  void _onConnectionEvent(IrohConnectionEvent event) {
    final nodeIdHex = event.nodeId.toHex();
    switch (event.type) {
      case IrohConnectionEventType.connected:
        _log.i('Iroh peer connected: $nodeIdHex');
        onPeerTransportConnected(nodeIdHex);
      case IrohConnectionEventType.disconnected:
        _log.i('Iroh peer disconnected: $nodeIdHex');
        onPeerTransportDisconnected(nodeIdHex);
    }
  }

  // ===== Accept Loop =====

  void _startAcceptLoop() {
    if (_endpoint == null) return;

    // Continuously accept incoming connections in the background
    unawaited(_acceptLoop());
  }

  Future<void> _acceptLoop() async {
    while (_endpoint != null && _state != TransportState.disposed) {
      try {
        final conn = await _endpoint!.accept();
        final nodeIdHex = conn.remoteNodeId.toHex();
        _log.i('Accepted connection from ${nodeIdHex.substring(0, 16)}...');

        // Handle the connection in the background
        unawaited(_handleIncomingConnection(conn));
      } catch (e) {
        if (_state == TransportState.disposed) break;
        _log.e('Error accepting connection: $e');
        // Brief pause before retrying
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _handleIncomingConnection(IrohConnection conn) async {
    try {
      final stream = await conn.acceptBi();
      final data = await stream.read();
      final nodeIdHex = conn.remoteNodeId.toHex();

      if (data.isNotEmpty) {
        _log.d('Received ${data.length} bytes from ${nodeIdHex.substring(0, 16)}...');
        onDataReceived(nodeIdHex, Uint8List.fromList(data));
      }

      await stream.close();
      await conn.close();
    } catch (e) {
      _log.e('Error handling incoming connection: $e');
    }
  }

  // ===== Internal =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  /// Find a peer in the store by their iroh NodeId hex
  PeerState? _findPeerByNodeIdHex(String nodeIdHex) {
    for (final peer in store.state.peers.peersList) {
      if (peer.irohNodeIdHex == nodeIdHex) {
        return peer;
      }
    }
    return null;
  }
}
