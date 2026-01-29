import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../ble/ble_central_service.dart';
import '../ble/ble_peripheral_service.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../store/store.dart';
import '../mesh/bloom_filter.dart';  // TODO: Move to utils/

/// Default display info for BLE transport
const _defaultBleDisplayInfo = TransportDisplayInfo(
  icon: Icons.bluetooth,
  name: 'Bluetooth',
  description: 'Bluetooth Low Energy direct P2P transport',
  color: Colors.blue,
);

/// BLE-based implementation of the transport service.
///
/// Provides direct peer-to-peer communication over Bluetooth Low Energy.
/// Each device runs both Central (scanner) and Peripheral (advertiser) modes
/// to maximize connectivity.
///
/// ## Architecture
///
/// - **Peripheral mode**: Advertises presence, accepts incoming connections
/// - **Central mode**: Scans for peers, initiates outgoing connections
///
/// ## IMPORTANT: No Mesh/Forwarding
///
/// This is a **direct P2P transport only**:
/// - Messages are sent directly to recipients
/// - NO relaying/forwarding through intermediate peers
/// - NO store-and-forward for offline peers
/// - All routing/forwarding logic belongs in the GSG layer above
class BleTransportService extends TransportService {
  final Logger _log = Logger();

  /// BLE Service UUID (derived from user's public key)
  final String serviceUuid;

  /// Local device name for advertising
  final String? localName;

  /// Our identity
  final BitchatIdentity identity;
  
  /// Redux store for state management
  final Store<AppState> store;

  /// Central service (scanner/connector)
  late final BleCentralService _central;

  /// Peripheral service (advertiser)
  late final BlePeripheralService _peripheral;

  /// Bloom filter for packet deduplication
  final BloomFilter _seenPackets = BloomFilter();

  /// Fragment handler for large messages
  final _SimpleFragmentHandler _fragmentHandler = _SimpleFragmentHandler();

  /// Protocol version for ANNOUNCE
  static const int protocolVersion = 1;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController = StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====
  
  /// Called when an application message is received
  void Function(Uint8List senderPubkey, Uint8List payload)? onMessageReceived;
  
  /// Called when a new peer connects (after ANNOUNCE)
  void Function(Peer peer)? onPeerConnected;
  
  /// Called when an existing peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;
  
  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;
  
  // ===== Convenience getters for Redux state =====
  
  /// Get peers state from Redux store
  PeersState get _peersState => store.state.peers;

  BleTransportService({
    required this.serviceUuid,
    required this.identity,
    required this.store,
    this.localName,
  }) {
    _central = BleCentralService(serviceUuid: serviceUuid);
    _peripheral = BlePeripheralService(serviceUuid: serviceUuid);
  }

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.ble;

  @override
  TransportDisplayInfo get displayInfo => _defaultBleDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream => _connectionController.stream;

  /// @deprecated Use store.state.peers.discoveredBlePeersList instead
  @override
  Stream<TransportDiscoveryEvent> get discoveryStream => const Stream.empty();

  /// @deprecated Use store.state.peers.discoveredBlePeersList instead
  @override
  List<TransportPeer> get peers => [];

  /// @deprecated Use store.state.peers.connectedPeers instead
  @override
  List<TransportPeer> get connectedPeers => [];

  @override
  int get connectedCount => _central.connectedCount + _peripheral.connectedCount;

  @override
  bool get isActive =>
      _state == TransportState.active &&
      (_central.isScanning || _peripheral.isAdvertising);

  /// Whether currently scanning for devices
  bool get isScanning => _central.isScanning;

  /// Get all known peers from Redux store
  List<PeerState> get knownPeers => _peersState.peersList;

  /// Get connected peers from Redux store
  List<PeerState> get connectedKnownPeers => _peersState.connectedPeers;

  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);

  /// Get peer by public key
  PeerState? getPeer(Uint8List pubkey) => _peersState.getPeerByPubkey(pubkey);
  
  /// Get all discovered BLE peers (before ANNOUNCE)
  List<DiscoveredPeerState> get discoveredPeers => _peersState.discoveredBlePeersList;

  // ===== Lifecycle =====

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('BLE transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing BLE transport service');

    try {
      // Set up central callbacks
      _central.onDataReceived = _onCentralDataReceived;
      _central.onConnectionChanged = _onCentralConnectionChanged;
      _central.onDeviceDiscovered = _onDeviceDiscovered;

      // Set up peripheral callbacks
      _peripheral.onDataReceived = _onPeripheralDataReceived;
      _peripheral.onConnectionChanged = _onPeripheralConnectionChanged;

      // Initialize both services
      await _central.initialize();
      await _peripheral.initialize();

      _setState(TransportState.ready);
      _log.i('BLE transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize BLE transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start BLE transport in state: $_state');
      return;
    }

    _log.i('Starting BLE transport');

    // Start advertising first (so others can find us)
    await _peripheral.startAdvertising(localName: localName);

    // Then start scanning (to find others)
    await _central.startScan();

    _setState(TransportState.active);
    _log.i('BLE transport started');
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping BLE transport');

    // Stop scanning for new devices
    await _central.stopScan();

    // Disconnect all connected devices explicitly
    await _central.disconnectAll();

    // Stop advertising and disconnect all centrals
    await _peripheral.stopAdvertising();

    if (_state == TransportState.active) {
      _setState(TransportState.ready);
    }

    _log.i('BLE transport stopped');
  }

  /// Trigger a new scan for peers
  Future<void> scan({Duration? timeout}) async {
    // _log.d('Starting BLE scan${timeout != null ? " for ${timeout.inSeconds}s" : ""}');
    await _central.startScan(timeout: timeout);
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    // _log.d('Connecting to peer: $peerId');
    return await _central.connectToDevice(peerId);
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    // _log.d('Disconnecting from peer: $peerId');
    await _central.disconnectFromDevice(peerId);
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    // Try central first (we initiated connection)
    if (await _central.sendData(peerId, data)) {
      return true;
    }
    // Try peripheral (they initiated connection)
    return await _peripheral.sendData(peerId, data);
  }

  @override
  Future<void> broadcast(Uint8List data, {String? excludePeerId}) async {
    await _central.broadcastData(data, excludeDevice: excludePeerId);
    await _peripheral.broadcastData(data, excludeDevice: excludePeerId);
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // Dispatch action to associate the device with pubkey in Redux store
    // Redux store is the single source of truth
    store.dispatch(AssociateBleDeviceAction(publicKey: pubkey, deviceId: peerId));
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // Look up in Redux store
    final peer = store.state.peers.getPeerByPubkey(pubkey);
    return peer?.bleDeviceId;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // Look up in Redux store - find peer with matching bleDeviceId
    for (final peer in store.state.peers.peersList) {
      if (peer.bleDeviceId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing BLE transport');

    await stop();
    await _central.dispose();
    await _peripheral.dispose();

    _fragmentHandler.dispose();

    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();

    _setState(TransportState.disposed);
  }

  // ===== Messaging =====

  /// Send a message directly to a specific peer.
  ///
  /// Returns true if sent successfully, false if peer is offline.
  /// NO forwarding - direct delivery only.
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
  }) async {
    // Create packet and check if serialized size exceeds BLE MTU
    final packet = _createMessagePacket(payload, recipientPubkey);
    final serialized = packet.serialize();

    if (serialized.length > _SimpleFragmentHandler.bleMaxPacketSize) {
      return _sendFragmented(payload: payload, recipientPubkey: recipientPubkey);
    }

    return _sendPacket(packet, recipientPubkey);
  }

  /// Broadcast a message to all connected peers.
  Future<void> broadcastMessage({required Uint8List payload}) async {
    final packet = _createMessagePacket(payload, null);
    final serialized = packet.serialize();

    if (serialized.length > _SimpleFragmentHandler.bleMaxPacketSize) {
      await _broadcastFragmented(payload: payload);
      return;
    }

    _seenPackets.add(packet.packetId);
    await broadcast(serialized);
  }

  /// Send ANNOUNCE to a specific peer
  Future<void> sendAnnounce(Uint8List peerPubkey) async {
    final payload = createAnnouncePayload();
    final packet = BitchatPacket(
      type: PacketType.announce,
      senderPubkey: identity.publicKey,
      recipientPubkey: peerPubkey,
      payload: payload,
      signature: Uint8List(64),
    );

    final peerId = getPeerIdForPubkey(peerPubkey);
    if (peerId != null) {
      final data = packet.serialize();
      await sendToPeer(peerId, data);
    }
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

  // ===== Internal Packet Handling =====

  BitchatPacket _createMessagePacket(Uint8List payload, Uint8List? recipientPubkey) {
    return BitchatPacket(
      type: PacketType.message,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // TODO: Sign packet
    );
  }

  Future<bool> _sendPacket(BitchatPacket packet, Uint8List recipientPubkey) async {
    _seenPackets.add(packet.packetId);

    if (!isPeerReachable(recipientPubkey)) {
      _log.d('Peer offline, cannot send message');
      return false;
    }

    final peerId = getPeerIdForPubkey(recipientPubkey);
    if (peerId == null) {
      _log.w('No peer ID found for pubkey');
      return false;
    }

    final data = packet.serialize();
    return await sendToPeer(peerId, data);
  }

  Future<bool> _sendFragmented({
    required Uint8List payload,
    required Uint8List recipientPubkey,
  }) async {
    final fragments = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
    );

    final peerId = getPeerIdForPubkey(recipientPubkey);
    if (peerId == null) {
      _log.w('No peer ID found for pubkey, cannot send fragments');
      return false;
    }

    var success = true;
    for (final fragment in fragments) {
      _seenPackets.add(fragment.packetId);

      final data = fragment.serialize();
      final sent = await sendToPeer(peerId, data);
      if (!sent) success = false;

      await Future.delayed(_SimpleFragmentHandler.fragmentDelay);
    }

    return success;
  }

  Future<void> _broadcastFragmented({required Uint8List payload}) async {
    final fragments = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
    );

    for (final fragment in fragments) {
      _seenPackets.add(fragment.packetId);
      final data = fragment.serialize();
      await broadcast(data);
      await Future.delayed(_SimpleFragmentHandler.fragmentDelay);
    }
  }

  /// Process an incoming packet
  void onPacketReceived(Uint8List data, {String? fromDeviceId, required int rssi}) {
    try {
      final packet = BitchatPacket.deserialize(data);
      _processPacket(packet, fromDeviceId: fromDeviceId, rssi: rssi);
    } catch (e) {
      _log.e('Failed to deserialize packet: $e');
    }
  }

  void _processPacket(BitchatPacket packet, {String? fromDeviceId, required int rssi}) {
    // Deduplication (except ANNOUNCE)
    if (packet.type != PacketType.announce) {
      if (_seenPackets.checkAndAdd(packet.packetId)) {
        _log.d('Duplicate packet dropped: ${packet.packetId}');
        return;
      }
    }

    switch (packet.type) {
      case PacketType.announce:
        _handleAnnounce(packet, fromDeviceId: fromDeviceId, rssi: rssi);
        break;

      case PacketType.message:
        _handleMessage(packet);
        break;

      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        _handleFragment(packet);
        break;

      case PacketType.ack:
      case PacketType.nack:
        // ACK/NACK handled by GSG layer
        onMessageReceived?.call(packet.senderPubkey, packet.payload);
        break;
    }
  }

  void _handleAnnounce(BitchatPacket packet, {String? fromDeviceId, required int rssi}) {
    final (pubkey, nickname, version) = _decodeAnnounce(packet.payload);
    
    // Determine RSSI: prefer our own scanned RSSI over the one from the connection
    // Since both devices run as Central+Peripheral, we likely scanned them too
    int effectiveRssi = rssi;
    
    // First try: lookup by device ID (works when we connected to them)
    DiscoveredPeerState? discoveredPeer;
    if (fromDeviceId != null) {
      discoveredPeer = _peersState.getDiscoveredBlePeer(fromDeviceId);
    }
    
    // Second try: lookup by service UUID (works when they connected to us on iOS)
    // Derive their service UUID from their pubkey
    if (discoveredPeer == null) {
      final theirServiceUuid = _deriveServiceUuidFromPubkey(pubkey);
      discoveredPeer = _peersState.findDiscoveredBlePeerByServiceUuid(theirServiceUuid);
      if (discoveredPeer != null) {
        _log.d('Found peer by service UUID: $theirServiceUuid');
      }
    }
    
    if (discoveredPeer != null) {
      effectiveRssi = discoveredPeer.rssi;
      // _log.d('Using our scanned RSSI ($effectiveRssi) instead of connection RSSI ($rssi)');
    } else {
      // _log.d('No scanned peer found, using connection RSSI: $rssi');
    }
    
    // Check if peer already exists
    final existingPeer = _peersState.getPeerByPubkey(pubkey);
    final isNew = existingPeer == null;

    // Dispatch action to Redux store
    store.dispatch(PeerAnnounceReceivedAction(
      publicKey: pubkey,
      nickname: nickname,
      protocolVersion: version,
      rssi: effectiveRssi,
      transport: PeerTransport.bleDirect,
      bleDeviceId: fromDeviceId,
    ));

    // Associate BLE device ID with pubkey
    if (fromDeviceId != null) {
      associatePeerWithPubkey(fromDeviceId, pubkey);
    }

    _log.i('Peer ${isNew ? "connected" : "updated"}: $nickname at RSSI $effectiveRssi');

    // Get the updated peer from store for callbacks
    final updatedPeer = _peersState.getPeerByPubkey(pubkey);
    if (updatedPeer != null) {
      // Convert PeerState to Peer for legacy callbacks
      final legacyPeer = _peerStateToLegacyPeer(updatedPeer);
      if (isNew) {
        onPeerConnected?.call(legacyPeer);
      } else {
        onPeerUpdated?.call(legacyPeer);
      }
    }
  }

  void _handleMessage(BitchatPacket packet) {
    // Direct delivery only - no forwarding
    if (_isForUs(packet)) {
      // _log.d('Message received for us');
      onMessageReceived?.call(packet.senderPubkey, packet.payload);
    } else {
      // NOT for us - drop it (no forwarding in this layer)
      _log.d('Message not for us, dropping (no forwarding)');
    }
  }

  void _handleFragment(BitchatPacket packet) {
    final reassembled = _fragmentHandler.processFragment(packet);

    if (reassembled != null && _isForUs(packet)) {
      _log.d('Fragmented message reassembled');
      onMessageReceived?.call(packet.senderPubkey, reassembled);
    }
    // If not for us, drop it (no forwarding)
  }

  bool _isForUs(BitchatPacket packet) {
    if (packet.isBroadcast) return true;
    if (packet.recipientPubkey == null) return true;
    
    return _pubkeyToHex(packet.recipientPubkey!) == _pubkeyToHex(identity.publicKey);
  }

  (Uint8List, String, int) _decodeAnnounce(Uint8List data) {
    final pubkey = data.sublist(0, 32);
    final version = ByteData.view(data.buffer, data.offsetInBytes + 32, 2)
        .getUint16(0, Endian.big);
    final nicknameLength = data[34];
    final nickname = String.fromCharCodes(data.sublist(35, 35 + nicknameLength));
    return (Uint8List.fromList(pubkey), nickname, version);
  }

  // ===== Peer Management =====

  void onPeerBleConnected(String bleDeviceId, {int? rssi}) {
    _log.d('BLE peer connected: $bleDeviceId');
  }

  void onPeerBleDisconnected(Uint8List pubkey) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    if (peer != null) {
      store.dispatch(PeerBleDisconnectedAction(pubkey));
      _log.i('Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(_peerStateToLegacyPeer(peer));
    }
  }

  // ===== BLE Callbacks =====

  void _onCentralDataReceived(String deviceId, Uint8List data, int rssi) {
    onPacketReceived(data, fromDeviceId: deviceId, rssi: rssi);
    
    _dataController.add(TransportDataEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      data: data,
    ));
  }

  void _onPeripheralDataReceived(String deviceId, Uint8List data, int rssi) {
    onPacketReceived(data, fromDeviceId: deviceId, rssi: rssi);
    
    _dataController.add(TransportDataEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      data: data,
    ));
  }

  void _onCentralConnectionChanged(String deviceId, bool connected) {
    _handleConnectionChange(deviceId, connected, isCentral: true);
  }

  void _onPeripheralConnectionChanged(String deviceId, bool connected) {
    _handleConnectionChange(deviceId, connected, isCentral: false);
  }

  void _onDeviceDiscovered(DiscoveredDevice device) {
    // Check if this is a new discovery
    final existing = _peersState.getDiscoveredBlePeer(device.deviceId);
    final isNew = existing == null;
    
    // Dispatch action to update Redux store
    store.dispatch(BleDeviceDiscoveredAction(
      deviceId: device.deviceId,
      displayName: device.name,
      rssi: device.rssi,
      serviceUuid: device.serviceUuid,
    ));
    
    // Also update RSSI for connected Peers (those who have sent ANNOUNCE)
    final pubkey = getPubkeyForPeerId(device.deviceId);
    if (pubkey != null) {
      store.dispatch(PeerRssiUpdatedAction(publicKey: pubkey, rssi: device.rssi));
    }
    
    // Auto-connect if this is a new discovery
    if (isNew) {
      _autoConnectToPeer(device.deviceId);
    }
  }
  
  /// Automatically connect to a discovered peer and send ANNOUNCE
  Future<bool> _autoConnectToPeer(String deviceId) async {
    // _log.i('Auto-connecting to peer: $deviceId');
    
    // Skip if already connected
    if (_isConnected(deviceId)) {
      _log.d('Already connected to $deviceId, skipping auto-connect');
      return false;
    }
    
    // Skip if already connecting
    final discovered = _peersState.getDiscoveredBlePeer(deviceId);
    if (discovered?.isConnecting == true) {
      // _log.d('Already connecting to $deviceId');
      return false;
    }
    
    // Mark as connecting in store
    store.dispatch(BleDeviceConnectingAction(deviceId));
    
    try {
      final success = await _central.connectToDevice(deviceId);
      
      if (success) {
        _log.i('Successfully connected to $deviceId');
        store.dispatch(BleDeviceConnectedAction(deviceId));
        
        // Send ANNOUNCE so peer learns our identity
        final announcePayload = createAnnouncePayload();
        final packet = BitchatPacket(
          type: PacketType.announce,
          senderPubkey: identity.publicKey,
          recipientPubkey: null, // broadcast to this peer
          payload: announcePayload,
          signature: Uint8List(64),
        );
        await sendToPeer(deviceId, packet.serialize());
        // _log.d('Sent ANNOUNCE to $deviceId');
        
        return true;
      } else {
        // _log.w('Failed to connect to $deviceId');
        store.dispatch(BleDeviceConnectionFailedAction(deviceId, error: 'Connection failed'));
        return false;
      }
    } catch (e) {
      // _log.e('Error auto-connecting to $deviceId: $e');
      store.dispatch(BleDeviceConnectionFailedAction(deviceId, error: e.toString()));
      return false;
    }
  }

  void _handleConnectionChange(String deviceId, bool connected, {required bool isCentral}) {
    if (connected) {
      store.dispatch(BleDeviceConnectedAction(deviceId));
      // _log.i('Peer connected: $deviceId (via ${isCentral ? "central" : "peripheral"})');
    } else {
      store.dispatch(BleDeviceDisconnectedAction(deviceId));
      final pubkey = getPubkeyForPeerId(deviceId);
      if (pubkey != null) {
        onPeerBleDisconnected(pubkey);
      }
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      connected: connected,
      reason: isCentral ? 'central' : 'peripheral',
    ));
  }

  // ===== Helpers =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  bool _isConnected(String peerId) {
    final centralConnected = _central.connectedPeers.any((p) => p.deviceId == peerId);
    final peripheralConnected = _peripheral.connectedCount > 0;
    return centralConnected || peripheralConnected;
  }

  /// Derive BLE Service UUID from a public key.
  /// Same algorithm as BitchatIdentity.bleServiceUuid
  String _deriveServiceUuidFromPubkey(Uint8List pubkey) {
    // Take last 16 bytes of the 32-byte public key
    final uuidBytes = pubkey.sublist(16, 32);
    
    // Format as UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
           '${hex.substring(8, 12)}-'
           '${hex.substring(12, 16)}-'
           '${hex.substring(16, 20)}-'
           '${hex.substring(20, 32)}';
  }

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  /// Convert PeerState to legacy Peer for backwards compatibility with callbacks
  Peer _peerStateToLegacyPeer(PeerState state) {
    return Peer(
      publicKey: state.publicKey,
      nickname: state.nickname,
      connectionState: state.connectionState,
      transport: state.transport,
      bleDeviceId: state.bleDeviceId,
      libp2pAddress: state.libp2pAddress,
      rssi: state.rssi,
      protocolVersion: state.protocolVersion,
    );
  }
}


// ===== Simple Fragment Handler (no TTL, direct P2P) =====

/// Simple fragment handler for large messages.
/// Used when payload exceeds BLE MTU (512 bytes).
class _SimpleFragmentHandler {
  /// Max BLE packet size (withoutResponse mode)
  static const int bleMaxPacketSize = 512;

  /// Max chunk size per fragment (512 - 152 header - ~20 metadata)
  static const int maxFragmentPayload = 340;
  static const Duration fragmentDelay = Duration(milliseconds: 20);

  final Map<String, _ReassemblyState> _reassemblyBuffer = {};

  List<BitchatPacket> fragment({
    required Uint8List payload,
    required Uint8List senderPubkey,
    Uint8List? recipientPubkey,
  }) {

    final messageId = DateTime.now().millisecondsSinceEpoch.toString();
    final fragments = <BitchatPacket>[];
    final totalFragments = (payload.length / maxFragmentPayload).ceil();

    for (var i = 0; i < totalFragments; i++) {
      final start = i * maxFragmentPayload;
      final end = (start + maxFragmentPayload).clamp(0, payload.length);
      final chunk = payload.sublist(start, end);

      final PacketType type;
      final Uint8List fragmentPayload;

      if (i == 0) {
        type = PacketType.fragmentStart;
        fragmentPayload = _encodeFragmentStart(messageId, totalFragments, payload.length, chunk);
      } else if (i == totalFragments - 1) {
        type = PacketType.fragmentEnd;
        fragmentPayload = _encodeFragmentContinue(messageId, i, chunk);
      } else {
        type = PacketType.fragmentContinue;
        fragmentPayload = _encodeFragmentContinue(messageId, i, chunk);
      }

      fragments.add(BitchatPacket(
        type: type,
        senderPubkey: senderPubkey,
        recipientPubkey: recipientPubkey,
        payload: fragmentPayload,
        signature: Uint8List(64),
      ));
    }

    return fragments;
  }

  Uint8List? processFragment(BitchatPacket packet) {
    if (packet.type == PacketType.fragmentStart) {
      final (messageId, totalFragments, totalSize, chunk) = _decodeFragmentStart(packet.payload);
      _reassemblyBuffer[messageId] = _ReassemblyState(
        messageId: messageId,
        totalFragments: totalFragments,
        totalSize: totalSize,
        senderPubkey: packet.senderPubkey,
      );
      _reassemblyBuffer[messageId]!.addChunk(0, chunk);
    } else {
      final (messageId, fragmentIndex, chunk) = _decodeFragmentContinue(packet.payload);
      final state = _reassemblyBuffer[messageId];
      if (state != null) {
        state.addChunk(fragmentIndex, chunk);
        if (state.isComplete) {
          final result = state.reassemble();
          _reassemblyBuffer.remove(messageId);
          return result;
        }
      }
    }
    return null;
  }

  Uint8List _encodeFragmentStart(String messageId, int totalFragments, int totalSize, Uint8List chunk) {
    final buffer = BytesBuilder();
    final msgIdBytes = Uint8List.fromList(messageId.codeUnits);
    buffer.addByte(msgIdBytes.length);
    buffer.add(msgIdBytes);
    buffer.addByte(totalFragments);
    final sizeBytes = ByteData(4)..setUint32(0, totalSize, Endian.big);
    buffer.add(sizeBytes.buffer.asUint8List());
    buffer.add(chunk);
    return buffer.toBytes();
  }

  Uint8List _encodeFragmentContinue(String messageId, int fragmentIndex, Uint8List chunk) {
    final buffer = BytesBuilder();
    final msgIdBytes = Uint8List.fromList(messageId.codeUnits);
    buffer.addByte(msgIdBytes.length);
    buffer.add(msgIdBytes);
    buffer.addByte(fragmentIndex);
    buffer.add(chunk);
    return buffer.toBytes();
  }

  (String, int, int, Uint8List) _decodeFragmentStart(Uint8List data) {
    var offset = 0;
    final msgIdLen = data[offset++];
    final messageId = String.fromCharCodes(data.sublist(offset, offset + msgIdLen));
    offset += msgIdLen;
    final totalFragments = data[offset++];
    final totalSize = ByteData.view(data.buffer, data.offsetInBytes + offset, 4).getUint32(0, Endian.big);
    offset += 4;
    final chunk = data.sublist(offset);
    return (messageId, totalFragments, totalSize, chunk);
  }

  (String, int, Uint8List) _decodeFragmentContinue(Uint8List data) {
    var offset = 0;
    final msgIdLen = data[offset++];
    final messageId = String.fromCharCodes(data.sublist(offset, offset + msgIdLen));
    offset += msgIdLen;
    final fragmentIndex = data[offset++];
    final chunk = data.sublist(offset);
    return (messageId, fragmentIndex, chunk);
  }

  void dispose() {
    _reassemblyBuffer.clear();
  }
}

class _ReassemblyState {
  final String messageId;
  final int totalFragments;
  final int totalSize;
  final Map<int, Uint8List> receivedChunks = {};
  final Uint8List senderPubkey;

  _ReassemblyState({
    required this.messageId,
    required this.totalFragments,
    required this.totalSize,
    required this.senderPubkey,
  });

  bool get isComplete => receivedChunks.length == totalFragments;

  void addChunk(int index, Uint8List data) {
    receivedChunks[index] = data;
  }

  Uint8List? reassemble() {
    if (!isComplete) return null;
    final result = BytesBuilder();
    for (var i = 0; i < totalFragments; i++) {
      final chunk = receivedChunks[i];
      if (chunk == null) return null;
      result.add(chunk);
    }
    return result.toBytes();
  }
}
