import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'peer.dart';
import 'package:logger/logger.dart';

/// Represents a discovered peer before identity (ANNOUNCE) is exchanged.
/// This is a transport-level concept - we know the device exists but don't
/// yet know who they are (pubkey/nickname).
/// 
/// Note: The transport type is implicit - DiscoveredPeer instances are stored
/// in transport-specific maps (_discoveredBlePeers, _discoveredLibp2pPeers).
/// A single identity (Peer) can be reachable via multiple transports.
class DiscoveredPeer {
  /// Transport-specific identifier (BLE device ID, libp2p peer ID, etc.)
  final String transportId;
  
  /// Human-readable name (from BLE advertising, etc.)
  String? displayName;
  
  /// Signal strength indicator (mutable - updated on each scan)
  /// For BLE: RSSI value (-100 to 0, higher is better)
  /// For other transports: may be 0 or a quality metric
  int rssi;
  
  /// Signal quality indicator (0.0 - 1.0), derived from rssi
  double get signalQuality {
    if (rssi >= -50) return 1.0;
    if (rssi <= -100) return 0.0;
    return (rssi + 100) / 50.0;
  }
  
  /// When this peer was first discovered
  final DateTime discoveredAt;
  
  /// When this peer was last seen
  DateTime lastSeen;
  
  /// Whether we're currently attempting to connect
  bool isConnecting;
  
  /// Whether we're currently connected (transport level, not app level)
  bool isConnected;
  
  /// Number of connection attempts
  int connectionAttempts;
  
  /// Last connection error, if any
  String? lastError;
  
  /// Public key if known (after ANNOUNCE exchange)
  /// Once this is set, the peer is also in the main _peers map
  Uint8List? publicKey;
  
  /// Transport-specific metadata (e.g., BLE service UUID, device object)
  Map<String, dynamic> _metadata;
  
  /// Get metadata map (never null)
  Map<String, dynamic> get metadata => _metadata;
  
  DiscoveredPeer({
    required this.transportId,
    this.displayName,
    required this.rssi,
    DateTime? discoveredAt,
    this.isConnecting = false,
    this.isConnected = false,
    this.connectionAttempts = 0,
    this.lastError,
    this.publicKey,
    Map<String, dynamic>? metadata,
  }) : discoveredAt = discoveredAt ?? DateTime.now(),
       lastSeen = discoveredAt ?? DateTime.now(),
       _metadata = metadata ?? {};
  
  /// Update last seen timestamp and RSSI
  void updateRssi(int newRssi) {
    lastSeen = DateTime.now();
    rssi = newRssi;
  }
  
  /// Whether we know this peer's identity (received ANNOUNCE)
  bool get isIdentified => publicKey != null;
  
  @override
  String toString() => 'DiscoveredPeer($transportId, name: $displayName, rssi: $rssi, connected: $isConnected, identified: $isIdentified)';
}

/// Central store for all peer data.
/// 
/// This is the **single source of truth** for peer information.
/// All components (routers, UI, transports) should use this store
/// instead of maintaining their own peer maps.
/// 
/// Usage:
/// ```dart
/// final store = PeerStore();
/// 
/// // Subscribe to changes
/// store.addListener(() {
///   print('Peers changed: ${store.connectedPeers.length} connected');
/// });
/// 
/// // Add/update peer
/// store.updatePeer(peer);
/// 
/// // Get peer by pubkey
/// final peer = store.getPeerByPubkey(pubkey);
/// ```
class PeerStore extends ChangeNotifier {
  final Logger _log = Logger();

  /// All known peers, keyed by pubkey hex
  final Map<String, Peer> _peers = {};
  
  // ===== Discovered Peers (per transport, before ANNOUNCE) =====
  
  /// Discovered BLE peers (by BLE device ID)
  final Map<String, DiscoveredPeer> _discoveredBlePeers = {};
  
  /// Discovered libp2p peers (by libp2p peer ID)
  final Map<String, DiscoveredPeer> _discoveredLibp2pPeers = {};
  
  /// Stream controller for new BLE peer discoveries
  final _newBleDiscoveryController = StreamController<DiscoveredPeer>.broadcast();
  
  /// Stream controller for new libp2p peer discoveries
  final _newLibp2pDiscoveryController = StreamController<DiscoveredPeer>.broadcast();
  
  /// Stream of newly discovered BLE peers (fires only for NEW discoveries)
  Stream<DiscoveredPeer> get onNewBleDiscovery => _newBleDiscoveryController.stream;
  
  /// Stream of newly discovered libp2p peers (fires only for NEW discoveries)
  Stream<DiscoveredPeer> get onNewLibp2pDiscovery => _newLibp2pDiscoveryController.stream;

  /// Get all discovered BLE peers
  List<DiscoveredPeer> get discoveredBlePeers => _discoveredBlePeers.values.toList();
  
  /// Get all discovered libp2p peers
  List<DiscoveredPeer> get discoveredLibp2pPeers => _discoveredLibp2pPeers.values.toList();

  /// Get all known peers
  List<Peer> get allPeers => _peers.values.toList();

  /// Get connected peers only
  List<Peer> get connectedPeers => _peers.values
      .where((p) => p.connectionState == PeerConnectionState.connected)
      .toList();

  /// Get peers reachable via BLE
  List<Peer> get blePeers => _peers.values
      .where((p) => p.addresses.hasBleAddress)
      .toList();

  /// Get peers reachable via libp2p
  List<Peer> get libp2pPeers => _peers.values
      .where((p) => p.addresses.hasLibp2pAddress)
      .toList();

  /// Number of connected peers
  int get connectedCount => connectedPeers.length;

  /// Number of all known peers
  int get totalCount => _peers.length;

  /// Check if a peer exists by pubkey
  bool hasPeer(Uint8List pubkey) => _peers.containsKey(_pubkeyToHex(pubkey));

  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    return peer?.isReachable ?? false;
  }

  /// Get peer by public key
  Peer? getPeerByPubkey(Uint8List pubkey) => _peers[_pubkeyToHex(pubkey)];

  /// Get peer by pubkey hex string
  Peer? getPeerByHex(String pubkeyHex) => _peers[pubkeyHex];

  /// Get peer by BLE device ID
  Peer? getPeerByBleDeviceId(String deviceId) {
    return _peers.values.where((p) => p.addresses.bleDeviceId == deviceId).firstOrNull;
  }

  /// Get peer by libp2p peer ID
  Peer? getPeerByLibp2pAddress(String address) {
    return _peers.values.where((p) => p.addresses.libp2pAddress == address).firstOrNull;
  }

  // ===== Discovered Peer Management =====
  
  /// Add or update a discovered BLE peer.
  /// Returns true if this is a NEW discovery (not an update).
  /// Emits to onNewBleDiscovery stream if new.
  bool addDiscoveredBlePeer({
    required String deviceId,
    String? displayName,
    required int rssi,
    Map<String, dynamic>? metadata,
  }) {
    final existing = _discoveredBlePeers[deviceId];
    final isNew = existing == null;
    
    if (isNew) {
      _log.i("New BLE peer discovered: ${displayName ?? deviceId} at rssi $rssi");
      final peer = DiscoveredPeer(
        transportId: deviceId,
        displayName: displayName,
        rssi: rssi,
        metadata: metadata,
      );
      _discoveredBlePeers[deviceId] = peer;
      _newBleDiscoveryController.add(peer);
      notifyListeners();
    } else {
      // Use existing displayName if new one is null/empty
      final effectiveDisplayName = (displayName != null && displayName.isNotEmpty) 
          ? displayName 
          : existing.displayName ?? deviceId;
      _log.d("Updating $effectiveDisplayName: rssi $rssi");
      // Update existing - update RSSI, lastSeen, displayName, and metadata
      existing.updateRssi(rssi);
      if (displayName != null && displayName.isNotEmpty) existing.displayName = displayName;
      if (metadata != null) existing.metadata.addAll(metadata);
      notifyListeners();
    }
    
    return isNew;
  }
  
  /// Get a discovered BLE peer by device ID
  DiscoveredPeer? getDiscoveredBlePeer(String deviceId) {
    return _discoveredBlePeers[deviceId];
  }
  
  /// Find a discovered BLE peer by service UUID (stored in metadata)
  /// This is useful for correlating when device IDs don't match (iOS issue)
  DiscoveredPeer? findDiscoveredBlePeerByServiceUuid(String serviceUuid) {
    final lowerUuid = serviceUuid.toLowerCase();
    for (final peer in _discoveredBlePeers.values) {
      final peerServiceUuid = peer.metadata['serviceUuid'] as String?;
      if (peerServiceUuid != null && peerServiceUuid.toLowerCase() == lowerUuid) {
        return peer;
      }
    }
    return null;
  }
  
  /// Mark a discovered BLE peer as connecting
  void markBleDiscoveredConnecting(String deviceId) {
    final peer = _discoveredBlePeers[deviceId];
    if (peer != null) {
      peer.isConnecting = true;
      peer.connectionAttempts++;
      notifyListeners();
    }
  }
  
  /// Mark a discovered BLE peer as connected (transport level)
  void markBleDiscoveredConnected(String deviceId) {
    final peer = _discoveredBlePeers[deviceId];
    if (peer != null) {
      peer.isConnecting = false;
      peer.isConnected = true;
      peer.lastError = null;
      notifyListeners();
    }
  }
  
  /// Mark a discovered BLE peer connection as failed
  void markBleDiscoveredFailed(String deviceId, String? error) {
    final peer = _discoveredBlePeers[deviceId];
    if (peer != null) {
      peer.isConnecting = false;
      peer.isConnected = false;
      peer.lastError = error;
      notifyListeners();
    }
  }
  
  /// Mark a discovered BLE peer as disconnected
  void markBleDiscoveredDisconnected(String deviceId) {
    final peer = _discoveredBlePeers[deviceId];
    if (peer != null) {
      peer.isConnecting = false;
      peer.isConnected = false;
      notifyListeners();
    }
  }
  
  /// Remove a discovered BLE peer
  void removeDiscoveredBlePeer(String deviceId) {
    if (_discoveredBlePeers.remove(deviceId) != null) {
      notifyListeners();
    }
  }
  
  /// Add or update a discovered libp2p peer.
  /// Returns true if this is a NEW discovery.
  bool addDiscoveredLibp2pPeer({
    required String peerId,
    String? displayName,
    int rssi = 0,
  }) {
    final existing = _discoveredLibp2pPeers[peerId];
    final isNew = existing == null;
    
    if (isNew) {
      final peer = DiscoveredPeer(
        transportId: peerId,
        displayName: displayName,
        rssi: rssi,
      );
      _discoveredLibp2pPeers[peerId] = peer;
      _newLibp2pDiscoveryController.add(peer);
      notifyListeners();
    } else {
      existing.lastSeen = DateTime.now();
    }
    
    return isNew;
  }
  
  /// Clear all discovered peers (useful on transport restart)
  void clearDiscoveredPeers() {
    _discoveredBlePeers.clear();
    _discoveredLibp2pPeers.clear();
    notifyListeners();
  }
  
  /// Remove stale discovered BLE peers that haven't been seen within the threshold.
  /// These are peers we discovered via BLE scan but never exchanged ANNOUNCE with.
  /// 
  /// Returns the number of removed peers.
  int removeStaleDiscoveredBlePeers(Duration staleThreshold) {
    final now = DateTime.now();
    final staleIds = <String>[];

    _log.i('Have ${_discoveredBlePeers.length} discovered BLE peers before stale removal');
    
    for (final entry in _discoveredBlePeers.entries) {
      final timeSinceLastSeen = now.difference(entry.value.lastSeen);
      if (timeSinceLastSeen > staleThreshold) {
        staleIds.add(entry.key);
      }
    }
    
    for (final id in staleIds) {
      _discoveredBlePeers.remove(id);
    }
    
    if (staleIds.isNotEmpty) {
      notifyListeners();
    }
    
    return staleIds.length;
  }
  
  /// Remove stale discovered libp2p peers that haven't been seen within the threshold.
  /// 
  /// Returns the number of removed peers.
  int removeStaleDiscoveredLibp2pPeers(Duration staleThreshold) {
    final now = DateTime.now();
    final staleIds = <String>[];
    
    for (final entry in _discoveredLibp2pPeers.entries) {
      final timeSinceLastSeen = now.difference(entry.value.lastSeen);
      if (timeSinceLastSeen > staleThreshold) {
        staleIds.add(entry.key);
      }
    }
    
    for (final id in staleIds) {
      _discoveredLibp2pPeers.remove(id);
    }
    
    if (staleIds.isNotEmpty) {
      notifyListeners();
    }
    
    return staleIds.length;
  }
  
  /// Dispose stream controllers
  void dispose() {
    _newBleDiscoveryController.close();
    _newLibp2pDiscoveryController.close();
    super.dispose();
  }

  /// Add or update a peer.
  /// 
  /// If the peer already exists, it will be updated.
  /// Notifies listeners of the change.
  Peer addOrUpdatePeer({
    required Uint8List publicKey,
    String? nickname,
    PeerConnectionState? connectionState,
    PeerTransport? transport,
    String? bleDeviceId,
    String? libp2pAddress,
    int? rssi,
    int? protocolVersion,
  }) {
    final hex = _pubkeyToHex(publicKey);
    var peer = _peers[hex];

    if (peer == null) {
      // Create new peer
      peer = Peer(
        publicKey: publicKey,
        nickname: nickname ?? '',
        connectionState: connectionState ?? PeerConnectionState.discovered,
        transport: transport ?? PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        libp2pAddress: libp2pAddress,
        rssi: rssi ?? -100,
        protocolVersion: protocolVersion ?? 1,
      );
      _peers[hex] = peer;
    } else {
      // Update existing peer
      if (nickname != null) peer.nickname = nickname;
      if (connectionState != null) peer.connectionState = connectionState;
      if (transport != null) peer.transport = transport;
      if (bleDeviceId != null) peer.addresses.updateBleAddress(bleDeviceId);
      if (libp2pAddress != null) peer.addresses.updateLibp2pAddress(libp2pAddress);
      if (rssi != null) peer.rssi = rssi;
      if (protocolVersion != null) peer.protocolVersion = protocolVersion;
    }

    notifyListeners();
    return peer;
  }

  /// Update peer from an ANNOUNCE packet
  Peer updateFromAnnounce({
    required Uint8List publicKey,
    required String nickname,
    required int protocolVersion,
    required DateTime receivedAt,
    String? libp2pAddress,
    String? bleDeviceId,
    int? rssi,
    PeerTransport? transport,
  }) {
    final hex = _pubkeyToHex(publicKey);
    var peer = _peers[hex];
    final isNew = peer == null;

    if (isNew) {
      peer = Peer(
        publicKey: publicKey,
        nickname: nickname,
        connectionState: PeerConnectionState.connected,
        transport: transport ?? PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        libp2pAddress: libp2pAddress,
        rssi: rssi ?? -100,
        protocolVersion: protocolVersion,
      );
      _peers[hex] = peer;
    } else {
      peer.updateFromAnnounce(
        nickname: nickname,
        protocolVersion: protocolVersion,
        receivedAt: receivedAt,
        libp2pAddress: libp2pAddress,
      );
      if (bleDeviceId != null) peer.addresses.updateBleAddress(bleDeviceId);
      if (rssi != null) peer.rssi = rssi;
      if (transport != null) peer.transport = transport;
    }

    peer.lastSeen = receivedAt;
    notifyListeners();
    return peer;
  }

  /// Mark a peer as disconnected from BLE
  void markBleDisconnected(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.markBleDisconnected();
      notifyListeners();
    }
  }

  /// Mark a peer as disconnected from libp2p
  void markLibp2pDisconnected(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.markLibp2pDisconnected();
      notifyListeners();
    }
  }

  /// Mark a peer as fully disconnected (from all transports)
  void markDisconnected(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.markDisconnected();
      notifyListeners();
    }
  }

  /// Clear libp2p address for a peer (used when unfriending)
  void clearLibp2pAddress(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.addresses.clearLibp2pAddress();
      notifyListeners();
    }
  }

  /// Remove a peer completely
  Peer? removePeer(Uint8List pubkey) {
    final peer = _peers.remove(_pubkeyToHex(pubkey));
    if (peer != null) {
      notifyListeners();
    }
    return peer;
  }

  /// Remove stale peers that haven't been seen within the threshold.
  /// 
  /// Peers are fully removed from the store (not just marked disconnected)
  /// because if we haven't received an ANNOUNCE in 2x the interval,
  /// they're likely out of range.
  /// 
  /// Returns list of removed peers.
  List<Peer> removeStalePeers(Duration staleThreshold) {
    final now = DateTime.now();
    final stale = <Peer>[];
    final staleHexKeys = <String>[];

    for (final entry in _peers.entries) {
      final peer = entry.value;
      // Only check connected peers - disconnected peers are already "stale"
      if (peer.connectionState == PeerConnectionState.connected) {
        if (peer.lastSeen != null) {
          final timeSinceLastSeen = now.difference(peer.lastSeen!);
          if (timeSinceLastSeen > staleThreshold) {
            stale.add(peer);
            staleHexKeys.add(entry.key);
          }
        }
      }
    }

    // Actually remove from the map
    for (final hexKey in staleHexKeys) {
      _peers.remove(hexKey);
    }

    if (stale.isNotEmpty) {
      notifyListeners();
    }

    return stale;
  }

  /// Update BLE device ID association for a peer
  void associateBleDevice(Uint8List pubkey, String deviceId) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.addresses.updateBleAddress(deviceId);
      notifyListeners();
    }
  }

  /// Update RSSI for a peer (called on every scan result)
  void updatePeerRssi(Uint8List pubkey, int rssi) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.rssi = rssi;
      peer.lastSeen = DateTime.now();
      notifyListeners();
    }
  }

  /// Update libp2p address association for a peer
  void associateLibp2pAddress(Uint8List pubkey, String address) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.addresses.updateLibp2pAddress(address);
      notifyListeners();
    }
  }

  /// Touch a peer's BLE last seen timestamp
  void touchBlePeer(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.addresses.touchBle();
      peer.lastSeen = DateTime.now();
      notifyListeners();
    }
  }

  /// Touch a peer's libp2p last seen timestamp  
  void touchLibp2pPeer(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    if (peer != null) {
      peer.addresses.touchLibp2p();
      peer.lastSeen = DateTime.now();
      notifyListeners();
    }
  }

  /// Clear all peers
  void clear() {
    _peers.clear();
    notifyListeners();
  }

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
