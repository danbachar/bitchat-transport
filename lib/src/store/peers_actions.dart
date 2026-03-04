import 'dart:typed_data';
import '../models/peer.dart';

/// Base class for peer-related actions
abstract class PeerAction {}

// ===== BLE Discovery Actions =====

/// A BLE device was discovered during scan
class BleDeviceDiscoveredAction extends PeerAction {
  final String deviceId;
  final String? displayName;
  final int rssi;
  final String? serviceUuid;

  BleDeviceDiscoveredAction({
    required this.deviceId,
    this.displayName,
    required this.rssi,
    this.serviceUuid,
  });
}

/// RSSI updated for a discovered BLE device
class BleDeviceRssiUpdatedAction extends PeerAction {
  final String deviceId;
  final int rssi;

  BleDeviceRssiUpdatedAction({
    required this.deviceId,
    required this.rssi,
  });
}

/// Mark a discovered BLE device as connecting
class BleDeviceConnectingAction extends PeerAction {
  final String deviceId;

  BleDeviceConnectingAction(this.deviceId);
}

/// Mark a discovered BLE device as connected (transport level)
class BleDeviceConnectedAction extends PeerAction {
  final String deviceId;

  BleDeviceConnectedAction(this.deviceId);
}

/// Mark a discovered BLE device connection as failed
class BleDeviceConnectionFailedAction extends PeerAction {
  final String deviceId;
  final String? error;

  BleDeviceConnectionFailedAction(this.deviceId, {this.error});
}

/// Mark a discovered BLE device as disconnected
class BleDeviceDisconnectedAction extends PeerAction {
  final String deviceId;

  BleDeviceDisconnectedAction(this.deviceId);
}

/// Remove a discovered BLE device
class BleDeviceRemovedAction extends PeerAction {
  final String deviceId;

  BleDeviceRemovedAction(this.deviceId);
}

/// Remove stale discovered BLE devices
class StaleDiscoveredBlePeersRemovedAction extends PeerAction {
  final Duration staleThreshold;

  StaleDiscoveredBlePeersRemovedAction(this.staleThreshold);
}

/// Clear all discovered BLE peers
class ClearDiscoveredBlePeersAction extends PeerAction {}

// ===== Iroh Discovery Actions =====

/// An iroh peer was discovered
class IrohPeerDiscoveredAction extends PeerAction {
  final String nodeIdHex;
  final String? displayName;

  IrohPeerDiscoveredAction({
    required this.nodeIdHex,
    this.displayName,
  });
}

/// Clear all discovered iroh peers
class ClearDiscoveredIrohPeersAction extends PeerAction {}

// ===== Peer Identity Actions (after ANNOUNCE) =====

/// An ANNOUNCE packet was received - add or update peer identity
class PeerAnnounceReceivedAction extends PeerAction {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final int rssi;
  final PeerTransport transport;
  final String? bleDeviceId;

  /// Iroh addressing info from the ANNOUNCE
  final String? irohRelayUrl;
  final List<String> irohDirectAddresses;

  PeerAnnounceReceivedAction({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    required this.rssi,
    this.transport = PeerTransport.bleDirect,
    this.bleDeviceId,
    this.irohRelayUrl,
    this.irohDirectAddresses = const [],
  });
}

/// Update peer RSSI
class PeerRssiUpdatedAction extends PeerAction {
  final Uint8List publicKey;
  final int rssi;

  PeerRssiUpdatedAction({
    required this.publicKey,
    required this.rssi,
  });
}

/// Mark peer as disconnected from BLE
class PeerBleDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerBleDisconnectedAction(this.publicKey);
}

/// Mark peer as disconnected from iroh
class PeerIrohDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerIrohDisconnectedAction(this.publicKey);
}

/// Mark peer as fully disconnected
class PeerDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerDisconnectedAction(this.publicKey);
}

/// Remove peer completely
class PeerRemovedAction extends PeerAction {
  final Uint8List publicKey;

  PeerRemovedAction(this.publicKey);
}

/// Remove stale peers that haven't been seen
class StalePeersRemovedAction extends PeerAction {
  final Duration staleThreshold;

  StalePeersRemovedAction(this.staleThreshold);
}

/// Clear all peers
class ClearAllPeersAction extends PeerAction {}

// ===== Association Actions =====

/// Associate a BLE device ID with a pubkey
class AssociateBleDeviceAction extends PeerAction {
  final Uint8List publicKey;
  final String deviceId;

  AssociateBleDeviceAction({
    required this.publicKey,
    required this.deviceId,
  });
}

/// Mark a peer as connected via iroh
class AssociateIrohConnectionAction extends PeerAction {
  final Uint8List publicKey;
  final String? relayUrl;
  final List<String>? directAddresses;

  AssociateIrohConnectionAction({
    required this.publicKey,
    this.relayUrl,
    this.directAddresses,
  });
}

// ===== Friendship Actions =====

/// A friendship has been established - mark peer as friend
class FriendEstablishedAction extends PeerAction {
  final Uint8List publicKey;
  final String? nickname;

  FriendEstablishedAction({
    required this.publicKey,
    this.nickname,
  });
}

/// A friendship has been removed
class FriendRemovedAction extends PeerAction {
  final Uint8List publicKey;

  FriendRemovedAction(this.publicKey);
}
