import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/peer.dart';

/// Represents a discovered peer before identity (ANNOUNCE) is exchanged.
/// Immutable version for Redux state.
@immutable
class DiscoveredPeerState {
  /// Transport-specific identifier (BLE device ID, iroh node ID, etc.)
  final String transportId;

  /// Human-readable name (from BLE advertising, etc.)
  final String? displayName;

  /// Signal strength indicator
  final int rssi;

  /// When this peer was first discovered
  final DateTime discoveredAt;

  /// When this peer was last seen
  final DateTime lastSeen;

  /// Whether we're currently attempting to connect
  final bool isConnecting;

  /// Whether we're currently connected (transport level)
  final bool isConnected;

  /// Number of connection attempts
  final int connectionAttempts;

  /// Last connection error, if any
  final String? lastError;

  /// Public key if known (after ANNOUNCE exchange)
  final Uint8List? publicKey;

  /// Service UUID (for correlation on iOS)
  final String? serviceUuid;

  const DiscoveredPeerState({
    required this.transportId,
    this.displayName,
    required this.rssi,
    required this.discoveredAt,
    required this.lastSeen,
    this.isConnecting = false,
    this.isConnected = false,
    this.connectionAttempts = 0,
    this.lastError,
    this.publicKey,
    this.serviceUuid,
  });

  /// Signal quality indicator (0.0 - 1.0), derived from rssi
  double get signalQuality {
    if (rssi >= -50) return 1.0;
    if (rssi <= -100) return 0.0;
    return (rssi + 100) / 50.0;
  }

  /// Whether we know this peer's identity (received ANNOUNCE)
  bool get isIdentified => publicKey != null;

  DiscoveredPeerState copyWith({
    String? transportId,
    String? displayName,
    int? rssi,
    DateTime? discoveredAt,
    DateTime? lastSeen,
    bool? isConnecting,
    bool? isConnected,
    int? connectionAttempts,
    String? lastError,
    Uint8List? publicKey,
    String? serviceUuid,
  }) {
    return DiscoveredPeerState(
      transportId: transportId ?? this.transportId,
      displayName: displayName ?? this.displayName,
      rssi: rssi ?? this.rssi,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      lastSeen: lastSeen ?? this.lastSeen,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      connectionAttempts: connectionAttempts ?? this.connectionAttempts,
      lastError: lastError ?? this.lastError,
      publicKey: publicKey ?? this.publicKey,
      serviceUuid: serviceUuid ?? this.serviceUuid,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeerState &&
          runtimeType == other.runtimeType &&
          transportId == other.transportId &&
          rssi == other.rssi &&
          isConnecting == other.isConnecting &&
          isConnected == other.isConnected &&
          connectionAttempts == other.connectionAttempts &&
          lastError == other.lastError &&
          serviceUuid == other.serviceUuid;

  @override
  int get hashCode => Object.hash(
    transportId,
    rssi,
    isConnecting,
    isConnected,
    connectionAttempts,
    lastError,
    serviceUuid,
  );

  @override
  String toString() => 'DiscoveredPeerState($transportId, rssi: $rssi, connected: $isConnected)';
}

/// Immutable peer state for identified peers (after ANNOUNCE)
@immutable
class PeerState {
  final Uint8List publicKey;
  final String nickname;
  final PeerConnectionState connectionState;
  final PeerTransport transport;
  final int rssi;
  final int protocolVersion;
  final DateTime? lastSeen;

  /// BLE device ID if connected via BLE
  final String? bleDeviceId;

  /// Whether this peer has a verified iroh connection
  final bool irohConnected;

  /// Whether this peer is a friend (friendship established)
  final bool isFriend;

  /// Iroh NodeId hex string for transport-level addressing.
  /// In iroh, NodeId IS the Ed25519 public key, so this equals pubkeyHex.
  String? get irohNodeIdHex => pubkeyHex;

  /// Iroh relay URL for this peer
  final String? irohRelayUrl;

  /// Iroh direct addresses for this peer (IP:port pairs)
  final List<String>? irohDirectAddresses;

  const PeerState({
    required this.publicKey,
    required this.nickname,
    this.connectionState = PeerConnectionState.discovered,
    this.transport = PeerTransport.bleDirect,
    this.rssi = -100,
    this.protocolVersion = 1,
    this.lastSeen,
    this.bleDeviceId,
    this.irohConnected = false,
    this.isFriend = false,
    this.irohRelayUrl,
    this.irohDirectAddresses,
  });

  /// Hex representation of public key (for map keys)
  String get pubkeyHex => publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Display name (nickname or truncated pubkey)
  String get displayName => nickname.isNotEmpty ? nickname : '${pubkeyHex.substring(0, 8)}...';

  /// Whether this peer is currently connected
  bool get isConnected => connectionState == PeerConnectionState.connected;

  /// Whether this peer is reachable via any transport
  bool get isReachable => bleDeviceId != null || irohConnected;

  /// The currently active transport based on available connections.
  /// BLE is preferred when available; falls back to iroh, then stored value.
  PeerTransport get activeTransport {
    if (bleDeviceId != null) return PeerTransport.bleDirect;
    if (irohConnected) return PeerTransport.iroh;
    return transport;
  }

  /// Signal quality (0.0 - 1.0)
  double get signalQuality {
    if (rssi >= -50) return 1.0;
    if (rssi <= -100) return 0.0;
    return (rssi + 100) / 50.0;
  }

  PeerState copyWith({
    Uint8List? publicKey,
    String? nickname,
    PeerConnectionState? connectionState,
    PeerTransport? transport,
    int? rssi,
    int? protocolVersion,
    DateTime? lastSeen,
    String? bleDeviceId,
    bool? irohConnected,
    bool? isFriend,
    String? irohRelayUrl,
    List<String>? irohDirectAddresses,
  }) {
    return PeerState(
      publicKey: publicKey ?? this.publicKey,
      nickname: nickname ?? this.nickname,
      connectionState: connectionState ?? this.connectionState,
      transport: transport ?? this.transport,
      rssi: rssi ?? this.rssi,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      lastSeen: lastSeen ?? this.lastSeen,
      bleDeviceId: bleDeviceId ?? this.bleDeviceId,
      irohConnected: irohConnected ?? this.irohConnected,
      isFriend: isFriend ?? this.isFriend,
      irohRelayUrl: irohRelayUrl ?? this.irohRelayUrl,
      irohDirectAddresses: irohDirectAddresses ?? this.irohDirectAddresses,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerState &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          nickname == other.nickname &&
          connectionState == other.connectionState &&
          transport == other.transport &&
          rssi == other.rssi &&
          bleDeviceId == other.bleDeviceId &&
          irohConnected == other.irohConnected &&
          isFriend == other.isFriend &&
          irohRelayUrl == other.irohRelayUrl;

  @override
  int get hashCode => Object.hash(
    pubkeyHex,
    nickname,
    connectionState,
    transport,
    rssi,
    bleDeviceId,
    irohConnected,
    isFriend,
    irohRelayUrl,
  );
}

/// Complete peers state for Redux store
@immutable
class PeersState {
  /// Discovered BLE peers (before ANNOUNCE), keyed by device ID
  final Map<String, DiscoveredPeerState> discoveredBlePeers;

  /// Discovered iroh peers (before ANNOUNCE), keyed by node ID hex
  final Map<String, DiscoveredPeerState> discoveredIrohPeers;

  /// Identified peers (after ANNOUNCE), keyed by pubkey hex
  final Map<String, PeerState> peers;

  const PeersState({
    this.discoveredBlePeers = const {},
    this.discoveredIrohPeers = const {},
    this.peers = const {},
  });

  static const PeersState initial = PeersState();

  // ===== Getters =====

  /// All discovered BLE peers as list
  List<DiscoveredPeerState> get discoveredBlePeersList => discoveredBlePeers.values.toList();

  /// All discovered iroh peers as list
  List<DiscoveredPeerState> get discoveredIrohPeersList => discoveredIrohPeers.values.toList();

  /// All identified peers as list
  List<PeerState> get peersList => peers.values.toList();

  /// Connected peers only
  List<PeerState> get connectedPeers =>
      peers.values.where((p) => p.isConnected).toList();

  /// Peers reachable via BLE
  List<PeerState> get blePeers =>
      peers.values.where((p) => p.bleDeviceId != null).toList();

  /// Nearby peers - connected peers reachable via BLE (in physical proximity)
  List<PeerState> get nearbyBlePeers =>
      peers.values.where((p) => p.isConnected && p.bleDeviceId != null).toList();

  /// Peers reachable via iroh
  List<PeerState> get irohPeers =>
      peers.values.where((p) => p.irohConnected).toList();

  /// All friends
  List<PeerState> get friends =>
      peers.values.where((p) => p.isFriend).toList();

  /// Online friends - friends connected via iroh only (not nearby via BLE).
  List<PeerState> get onlineFriends =>
      peers.values.where((p) => p.isFriend && p.isConnected && p.bleDeviceId == null && p.irohConnected).toList();

  /// Count of connected peers
  int get connectedCount => connectedPeers.length;

  /// Count of all discovered BLE devices
  int get discoveredBleCount => discoveredBlePeers.length;

  /// Get peer by pubkey hex
  PeerState? getPeerByPubkeyHex(String pubkeyHex) => peers[pubkeyHex];

  /// Get peer by pubkey bytes
  PeerState? getPeerByPubkey(Uint8List pubkey) {
    final hex = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return peers[hex];
  }

  /// Get discovered BLE peer by device ID
  DiscoveredPeerState? getDiscoveredBlePeer(String deviceId) =>
      discoveredBlePeers[deviceId];

  /// Find discovered BLE peer by service UUID
  DiscoveredPeerState? findDiscoveredBlePeerByServiceUuid(String serviceUuid) {
    final lowerUuid = serviceUuid.toLowerCase();
    for (final peer in discoveredBlePeers.values) {
      if (peer.serviceUuid?.toLowerCase() == lowerUuid) {
        return peer;
      }
    }
    return null;
  }

  /// Check if a peer is reachable by pubkey
  bool isPeerReachable(Uint8List pubkey) {
    final peer = getPeerByPubkey(pubkey);
    return peer?.isReachable ?? false;
  }

  // ===== Copy With =====

  PeersState copyWith({
    Map<String, DiscoveredPeerState>? discoveredBlePeers,
    Map<String, DiscoveredPeerState>? discoveredIrohPeers,
    Map<String, PeerState>? peers,
  }) {
    return PeersState(
      discoveredBlePeers: discoveredBlePeers ?? this.discoveredBlePeers,
      discoveredIrohPeers: discoveredIrohPeers ?? this.discoveredIrohPeers,
      peers: peers ?? this.peers,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeersState &&
          runtimeType == other.runtimeType &&
          mapEquals(discoveredBlePeers, other.discoveredBlePeers) &&
          mapEquals(discoveredIrohPeers, other.discoveredIrohPeers) &&
          mapEquals(peers, other.peers);

  @override
  int get hashCode => Object.hash(
    discoveredBlePeers.length,
    discoveredIrohPeers.length,
    peers.length,
  );
}
