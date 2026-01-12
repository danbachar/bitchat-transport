import 'package:flutter/foundation.dart';
import 'peers_state.dart';

/// Transport connection status
enum TransportConnectionStatus {
  /// Not initialized
  uninitialized,
  
  /// Initializing transports
  initializing,
  
  /// Ready but not active
  ready,
  
  /// Active and online
  online,
  
  /// Currently scanning for devices
  scanning,
  
  /// Error state
  error,
}

/// Main application state for redux
@immutable
class AppState {
  /// Current transport connection status
  final TransportConnectionStatus connectionStatus;
  
  /// Error message if in error state
  final String? errorMessage;
  
  /// Peers state (discovered and connected peers)
  final PeersState peers;
  
  const AppState({
    this.connectionStatus = TransportConnectionStatus.uninitialized,
    this.errorMessage,
    this.peers = const PeersState(),
  });
  
  /// Initial state
  static const AppState initial = AppState();
  
  // ===== Convenience getters that derive from peers state =====
  
  /// Number of nearby peers (discovered BLE devices)
  int get nearbyPeerCount => peers.discoveredBleCount;
  
  /// Number of connected peers (after ANNOUNCE)
  int get connectedPeerCount => peers.connectedCount;
  
  /// Number of online friends (TODO: implement friends list)
  int get onlineFriendsCount => 0;
  
  /// Create a copy with updated values
  AppState copyWith({
    TransportConnectionStatus? connectionStatus,
    String? errorMessage,
    PeersState? peers,
  }) {
    return AppState(
      connectionStatus: connectionStatus ?? this.connectionStatus,
      errorMessage: errorMessage ?? this.errorMessage,
      peers: peers ?? this.peers,
    );
  }
  
  /// Get display string for connection status
  String get statusDisplayString {
    switch (connectionStatus) {
      case TransportConnectionStatus.uninitialized:
        return 'Initializing...';
      case TransportConnectionStatus.initializing:
        return 'Starting BLE...';
      case TransportConnectionStatus.ready:
        return 'Ready';
      case TransportConnectionStatus.online:
        return 'Online';
      case TransportConnectionStatus.scanning:
        return 'Scanning for peers...';
      case TransportConnectionStatus.error:
        return errorMessage ?? 'Error';
    }
  }
  
  /// Whether status indicates a healthy/running state
  bool get isHealthy => 
      connectionStatus == TransportConnectionStatus.online ||
      connectionStatus == TransportConnectionStatus.scanning;
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppState &&
          runtimeType == other.runtimeType &&
          connectionStatus == other.connectionStatus &&
          errorMessage == other.errorMessage &&
          peers == other.peers;

  @override
  int get hashCode =>
      connectionStatus.hashCode ^
      errorMessage.hashCode ^
      peers.hashCode;
}
