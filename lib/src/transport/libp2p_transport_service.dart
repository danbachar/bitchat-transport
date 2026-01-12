import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import '../transport/transport_service.dart';
import '../models/identity.dart';
import '../models/peer.dart';
import '../models/peer_store.dart';
import '../mesh/bloom_filter.dart';

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
class LibP2PTransportService extends TransportService with TransportServiceMixin {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// LibP2P configuration
  final LibP2PConfig config;
  
  /// Central peer store - single source of truth
  final PeerStore peerStore;
  
  /// Bloom filter for packet deduplication
  final BloomFilter _seenPackets = BloomFilter();
  
  /// Protocol version
  static const int protocolVersion = 1;

  /// LibP2P host instance (to be initialized with dart_libp2p)
  Object? _host;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Map of libp2p peer IDs to pubkey hex
  final Map<String, String> _peerIdToPubkey = {};
  
  /// Map of pubkey hex to libp2p peer IDs
  final Map<String, String> _pubkeyToPeerId = {};

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController = StreamController<TransportConnectionEvent>.broadcast();

  // ===== Application-level callbacks =====
  
  /// Called when an application message is received
  void Function(Uint8List senderPubkey, Uint8List payload)? onMessageReceived;
  
  /// Called when a new peer connects (after ANNOUNCE)
  void Function(Peer peer)? onPeerConnected;
  
  /// Called when a peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;
  
  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;

  LibP2PTransportService({
    required this.identity,
    required this.peerStore,
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
  Stream<TransportConnectionEvent> get connectionStream => _connectionController.stream;

  /// @deprecated Use PeerStore.discoveredLibp2pPeers instead - the PeerStore is the single source of truth
  @override
  Stream<TransportDiscoveryEvent> get discoveryStream => Stream.empty();

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
      // TODO: Initialize dart_libp2p host here
      // final keyPair = await crypto_ed25519.generateEd25519KeyPair();
      // _host = await Libp2p.new_([...options...]);

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
      // TODO: Use dart_libp2p to send data
      // await _host?.newStream(peerId, protocolId).write(data);
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
    final hex = _pubkeyToHex(pubkey);
    _peerIdToPubkey[peerId] = hex;
    _pubkeyToPeerId[hex] = peerId;
    _log.d('Associated peer $peerId with pubkey');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) => _pubkeyToPeerId[_pubkeyToHex(pubkey)];

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    final hex = _peerIdToPubkey[peerId];
    if (hex == null) return null;
    return _hexToPubkey(hex);
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing LibP2P transport');
    await stop();
    _host = null;
    _peerIdToPubkey.clear();
    _pubkeyToPeerId.clear();
    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    _setState(TransportState.disposed);
  }

  // ===== Messaging API (same as BleTransportService) =====

  /// Send a message directly to a peer by pubkey
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
  }) async {
    final peerId = getPeerIdForPubkey(recipientPubkey);
    if (peerId == null) {
      _log.w('No peer ID found for pubkey');
      return false;
    }
    
    if (!peerStore.isPeerReachable(recipientPubkey)) {
      _log.d('Peer offline, cannot send message');
      return false;
    }
    
    // Create simple message envelope
    final envelope = _createMessageEnvelope(payload);
    return await sendToPeer(peerId, envelope);
  }

  /// Broadcast a message to all connected peers
  Future<void> broadcastMessage({required Uint8List payload}) async {
    final envelope = _createMessageEnvelope(payload);
    await broadcast(envelope);
  }

  /// Send our ANNOUNCE to all connected peers
  Future<void> sendAnnounce() async {
    final payload = createAnnouncePayload();
    await broadcast(payload);
  }

  /// Create ANNOUNCE payload
  Uint8List createAnnouncePayload() {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    return buffer.toBytes();
  }

  // ===== Packet Processing =====

  /// Process incoming data from a peer
  void onDataReceived(String peerId, Uint8List data, {int rssi = 0}) {
    _log.d('Data received from peer $peerId: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      data: data,
    ));

    // Try to parse as ANNOUNCE
    if (_tryHandleAnnounce(peerId, data)) {
      return;
    }

    // Otherwise treat as application message
    final pubkey = getPubkeyForPeerId(peerId);
    if (pubkey != null) {
      onMessageReceived?.call(pubkey, data);
    }
  }

  bool _tryHandleAnnounce(String peerId, Uint8List data) {
    try {
      if (data.length < 35) return false; // Too short for ANNOUNCE

      final pubkey = data.sublist(0, 32);
      final version = ByteData.view(data.buffer, data.offsetInBytes + 32, 2)
          .getUint16(0, Endian.big);
      final nicknameLength = data[34];
      
      if (data.length < 35 + nicknameLength) return false;
      
      final nickname = String.fromCharCodes(data.sublist(35, 35 + nicknameLength));

      // Check if peer already exists
      final existingPeer = peerStore.getPeerByPubkey(Uint8List.fromList(pubkey));
      final isNew = existingPeer == null;

      // Update central peer store
      final peer = peerStore.updateFromAnnounce(
        publicKey: Uint8List.fromList(pubkey),
        nickname: nickname,
        protocolVersion: version,
        receivedAt: DateTime.now(),
        libp2pAddress: peerId,
        transport: PeerTransport.libp2p,
      );

      // Associate peer ID with pubkey
      associatePeerWithPubkey(peerId, Uint8List.fromList(pubkey));

      _log.i('Peer ${isNew ? "connected" : "updated"}: ${peer.displayName}');

      if (isNew) {
        onPeerConnected?.call(peer);
      } else {
        onPeerUpdated?.call(peer);
      }

      return true;
    } catch (e) {
      return false;
    }
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
      final peer = peerStore.getPeerByPubkey(pubkey);
      if (peer != null) {
        peerStore.markLibp2pDisconnected(pubkey);
        _log.i('Peer disconnected: ${peer.displayName}');
        onPeerDisconnected?.call(peer);
      }
    }

    // Clean up mappings
    final hex = _peerIdToPubkey.remove(peerId);
    if (hex != null) {
      _pubkeyToPeerId.remove(hex);
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: false,
    ));
  }

  // ===== Helper Methods =====

  Uint8List _createMessageEnvelope(Uint8List payload) {
    // Simple envelope: just the payload
    // In a more complete implementation, this would include sender pubkey, etc.
    return payload;
  }

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _hexToPubkey(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
