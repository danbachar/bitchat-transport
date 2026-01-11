/// Transport layer abstraction for Bitchat.
/// 
/// This module provides:
/// - [TransportService]: Abstract interface for transport implementations
/// - [BleTransportService]: Bluetooth Low Energy mesh transport
/// - [LibP2PTransportService]: LibP2P peer-to-peer transport
/// 
/// Future implementations may include:
/// - WebRTC transport (STUN/TURN/TURNS)
/// - LoRaWAN transport
library;

export 'transport_service.dart';
export 'ble_transport_service.dart';
export 'libp2p_transport_service.dart';

// Re-export BLE types needed for advanced usage
// TOOD: we should define DiscoveredPeer and ConnectedPeer here
export '../ble/ble_central_service.dart' show DiscoveredDevice, ConnectedPeer;

// Re-export Router interface and implementations
export '../mesh/router.dart';
export '../mesh/mesh_router.dart';
export '../mesh/libp2p_router.dart';
