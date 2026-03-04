import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../transport/transport_service.dart';

/// Connection state of a peer
enum PeerConnectionState {
  /// Discovered via BLE scan but not connected
  discovered,

  /// BLE connection established, awaiting ANNOUNCE
  connecting,

  /// ANNOUNCE exchanged, peer identity known
  connected,

  /// Connection lost, may still have cached identity
  disconnected,
}

/// Transport type for peer communication
enum PeerTransport {
  /// Direct BLE connection (Central or Peripheral role)
  bleDirect,

  /// WebRTC P2P connection
  webrtc,

  /// Iroh P2P connection
  iroh,
}

/// Holds addresses for all available transports for a peer
class PeerAddresses {
  /// BLE device ID (MAC address on Android, UUID on iOS)
  String? bleDeviceId;

  /// Iroh relay URL for this peer
  String? irohRelayUrl;

  /// Iroh direct addresses for this peer
  List<String>? irohDirectAddresses;

  /// When the BLE address was last seen
  DateTime? bleLastSeen;

  /// When the iroh address was last seen
  DateTime? irohLastSeen;

  PeerAddresses({
    this.bleDeviceId,
    this.irohRelayUrl,
    this.irohDirectAddresses,
    this.bleLastSeen,
    this.irohLastSeen,
  });

  /// Whether we have a BLE address for this peer
  bool get hasBleAddress => bleDeviceId != null;

  /// Whether we have iroh addressing info for this peer
  bool get hasIrohAddress =>
      (irohRelayUrl != null && irohRelayUrl!.isNotEmpty) ||
      (irohDirectAddresses != null && irohDirectAddresses!.isNotEmpty);

  /// Whether we have any address for this peer
  bool get hasAnyAddress => hasBleAddress || hasIrohAddress;

  /// Get the best available transport for this peer
  /// Priority: Bluetooth > iroh (Bluetooth is preferred for proximity)
  PeerTransport? get preferredTransport {
    // Prefer BLE if recently seen (within 30 seconds)
    if (hasBleAddress && bleLastSeen != null) {
      final bleAge = DateTime.now().difference(bleLastSeen!);
      if (bleAge.inSeconds < 30) {
        return PeerTransport.bleDirect;
      }
    }

    // Fall back to iroh if available
    if (hasIrohAddress && irohLastSeen != null) {
      return PeerTransport.iroh;
    }

    // If BLE is stale but still available
    if (hasBleAddress) {
      return PeerTransport.bleDirect;
    }

    // Last resort: iroh even if not recently seen
    if (hasIrohAddress) {
      return PeerTransport.iroh;
    }

    return null;
  }

  /// Update BLE address
  void updateBleAddress(String? deviceId) {
    bleDeviceId = deviceId;
    if (deviceId != null) {
      bleLastSeen = DateTime.now();
    }
  }

  /// Update iroh addressing info
  void updateIrohAddress({String? relayUrl, List<String>? directAddresses}) {
    if (relayUrl != null) {
      irohRelayUrl = relayUrl;
    }
    if (directAddresses != null) {
      irohDirectAddresses = directAddresses;
    }
    irohLastSeen = DateTime.now();
  }

  /// Touch BLE last seen timestamp
  void touchBle() {
    if (hasBleAddress) {
      bleLastSeen = DateTime.now();
    }
  }

  /// Touch iroh last seen timestamp
  void touchIroh() {
    if (hasIrohAddress) {
      irohLastSeen = DateTime.now();
    }
  }

  /// Clear all addresses (on disconnect)
  void clear() {
    bleDeviceId = null;
    irohRelayUrl = null;
    irohDirectAddresses = null;
    bleLastSeen = null;
    irohLastSeen = null;
  }

  /// Clear only the iroh address (used when unfriending)
  void clearIrohAddress() {
    irohRelayUrl = null;
    irohDirectAddresses = null;
    irohLastSeen = null;
  }

  Map<String, dynamic> toJson() => {
        'bleDeviceId': bleDeviceId,
        'irohRelayUrl': irohRelayUrl,
        'irohDirectAddresses': irohDirectAddresses,
        'bleLastSeen': bleLastSeen?.toIso8601String(),
        'irohLastSeen': irohLastSeen?.toIso8601String(),
      };

  factory PeerAddresses.fromJson(Map<String, dynamic> json) => PeerAddresses(
        bleDeviceId: json['bleDeviceId'],
        irohRelayUrl: json['irohRelayUrl'],
        irohDirectAddresses: (json['irohDirectAddresses'] as List<dynamic>?)
            ?.cast<String>(),
        bleLastSeen: json['bleLastSeen'] != null
            ? DateTime.parse(json['bleLastSeen'])
            : null,
        irohLastSeen: json['irohLastSeen'] != null
            ? DateTime.parse(json['irohLastSeen'])
            : null,
      );

  @override
  String toString() => 'PeerAddresses(ble: $bleDeviceId, iroh: relay=$irohRelayUrl direct=${irohDirectAddresses?.length ?? 0})';
}

/// Extension to get display info for peer transport
extension PeerTransportDisplay on PeerTransport {
  /// Get the icon for this transport type
  Icon get icon {
    switch (this) {
      case PeerTransport.bleDirect:
        return const Icon(Icons.bluetooth_connected, size: 16, color: Colors.blue);
      case PeerTransport.webrtc:
        return const Icon(Icons.public, size: 16, color: Colors.blue);
      case PeerTransport.iroh:
        return const Icon(Icons.public, size: 16, color: Colors.green);
    }
  }

  /// Get the display name for this transport
  String get displayName {
    switch (this) {
      case PeerTransport.bleDirect:
        return 'Bluetooth';
      case PeerTransport.webrtc:
        return 'WebRTC';
      case PeerTransport.iroh:
        return 'Iroh';
    }
  }

  /// Convert from TransportType
  static PeerTransport fromTransportType(TransportType type, {bool isMesh = false}) {
    switch (type) {
      case TransportType.ble:
        return PeerTransport.bleDirect;
      case TransportType.webrtc:
        return PeerTransport.webrtc;
      case TransportType.iroh:
        return PeerTransport.iroh;
    }
  }
}

/// Represents a peer in the Bitchat network.
///
/// A peer can be:
/// - Directly connected via BLE
/// - Connected over iroh (Internet)
/// - Connected via both transports
/// - Known but currently unreachable
class Peer {
  /// Ed25519 public key (32 bytes) - primary identifier
  final Uint8List publicKey;

  /// Human-readable nickname from ANNOUNCE (may be empty)
  String nickname;

  /// Current connection state
  PeerConnectionState connectionState;

  /// How we are currently reaching this peer (best available)
  PeerTransport transport;

  /// All known addresses for this peer
  final PeerAddresses addresses;

  /// BLE device ID (platform-specific, used for connection management)
  String? get bleDeviceId => addresses.bleDeviceId;
  set bleDeviceId(String? value) => addresses.updateBleAddress(value);

  /// Iroh relay URL for this peer
  String? get irohRelayUrl => addresses.irohRelayUrl;

  /// Iroh direct addresses for this peer
  List<String>? get irohDirectAddresses => addresses.irohDirectAddresses;

  /// Last time we received data from this peer
  DateTime? lastSeen;

  /// Last time we successfully sent data to this peer
  DateTime? lastSentTo;

  /// Signal strength (RSSI) if available, for BLE connections
  int rssi;

  /// Protocol version from ANNOUNCE
  int protocolVersion;

  /// Whether this peer is reachable via BLE
  bool get isReachableViaBle => addresses.hasBleAddress &&
      (connectionState == PeerConnectionState.connected ||
       connectionState == PeerConnectionState.connecting);

  /// Whether this peer is reachable via iroh
  bool get isReachableViaIroh => addresses.hasIrohAddress;

  /// Whether this peer is reachable via any transport
  bool get isReachableViaAny => isReachableViaBle || isReachableViaIroh;

  Peer({
    required this.publicKey,
    this.nickname = '',
    this.connectionState = PeerConnectionState.discovered,
    required this.transport,
    String? bleDeviceId,
    String? irohRelayUrl,
    List<String>? irohDirectAddresses,
    PeerAddresses? addresses,
    this.lastSeen,
    this.lastSentTo,
    required this.rssi,
    this.protocolVersion = 1,
  }) : addresses = addresses ?? PeerAddresses(
          bleDeviceId: bleDeviceId,
          irohRelayUrl: irohRelayUrl,
          irohDirectAddresses: irohDirectAddresses,
        ) {
    if (publicKey.length != 32) {
      throw ArgumentError('Public key must be 32 bytes');
    }
  }

  /// Unique identifier string from public key (hex encoded)
  String get id => publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Short fingerprint for display (first 8 bytes, colon-separated)
  String get shortFingerprint {
    return publicKey.sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
  }

  /// Display name: nickname if available, otherwise short fingerprint
  String get displayName => nickname.isNotEmpty ? nickname : shortFingerprint;

  /// Whether this peer is currently reachable
  bool get isReachable =>
      connectionState == PeerConnectionState.connected ||
      connectionState == PeerConnectionState.connecting;

  /// Get the best transport to use for sending to this peer
  /// Priority: Bluetooth > iroh
  PeerTransport? get bestAvailableTransport => addresses.preferredTransport;

  /// Update peer state from a received ANNOUNCE
  void updateFromAnnounce({
    required String nickname,
    required int protocolVersion,
    required DateTime receivedAt,
    String? irohRelayUrl,
    List<String>? irohDirectAddresses,
  }) {
    this.nickname = nickname;
    this.protocolVersion = protocolVersion;
    lastSeen = receivedAt;
    connectionState = PeerConnectionState.connected;

    if (irohRelayUrl != null || (irohDirectAddresses != null && irohDirectAddresses.isNotEmpty)) {
      addresses.updateIrohAddress(
        relayUrl: irohRelayUrl,
        directAddresses: irohDirectAddresses,
      );
    }
  }

  /// Update the peer's transport addresses
  void updateAddresses({
    String? bleDeviceId,
    String? irohRelayUrl,
    List<String>? irohDirectAddresses,
  }) {
    if (bleDeviceId != null) {
      addresses.updateBleAddress(bleDeviceId);
    }
    if (irohRelayUrl != null || irohDirectAddresses != null) {
      addresses.updateIrohAddress(
        relayUrl: irohRelayUrl,
        directAddresses: irohDirectAddresses,
      );
    }

    final best = addresses.preferredTransport;
    if (best != null) {
      transport = best;
    }
  }

  /// Mark peer as disconnected from BLE
  void markBleDisconnected() {
    addresses.bleDeviceId = null;
    addresses.bleLastSeen = null;

    if (addresses.hasIrohAddress) {
      transport = PeerTransport.iroh;
    } else {
      connectionState = PeerConnectionState.disconnected;
      rssi = -100;
    }
  }

  /// Mark peer as disconnected from iroh
  void markIrohDisconnected() {
    addresses.irohLastSeen = null;

    if (addresses.hasBleAddress) {
      transport = PeerTransport.bleDirect;
    } else {
      connectionState = PeerConnectionState.disconnected;
    }
  }

  /// Mark peer as disconnected
  void markDisconnected() {
    connectionState = PeerConnectionState.disconnected;
    addresses.clear();
    rssi = -100;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Peer($displayName, $connectionState, $transport)';
}
