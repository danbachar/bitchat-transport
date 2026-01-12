import 'app_state.dart';

/// Base class for all actions
abstract class AppAction {}

// ===== Connection Status Actions =====

/// Set connection status to initializing
class SetInitializingAction extends AppAction {}

/// Set connection status to ready
class SetReadyAction extends AppAction {}

/// Set connection status to online (active but not scanning)
class SetOnlineAction extends AppAction {}

/// Set connection status to scanning
class SetScanningAction extends AppAction {}

/// Set connection status to error with message
class SetErrorAction extends AppAction {
  final String message;
  SetErrorAction(this.message);
}

/// Generic action to set any connection status
class SetConnectionStatusAction extends AppAction {
  final TransportConnectionStatus status;
  final String? errorMessage;
  
  SetConnectionStatusAction(this.status, {this.errorMessage});
}

// ===== Peer Count Actions =====

/// Update nearby peer count
class UpdateNearbyPeerCountAction extends AppAction {
  final int count;
  UpdateNearbyPeerCountAction(this.count);
}

/// Update connected peer count
class UpdateConnectedPeerCountAction extends AppAction {
  final int count;
  UpdateConnectedPeerCountAction(this.count);
}

/// Update online friends count
class UpdateOnlineFriendsCountAction extends AppAction {
  final int count;
  UpdateOnlineFriendsCountAction(this.count);
}

/// Update all counts at once
class UpdateAllCountsAction extends AppAction {
  final int nearbyPeerCount;
  final int connectedPeerCount;
  final int onlineFriendsCount;
  
  UpdateAllCountsAction({
    required this.nearbyPeerCount,
    required this.connectedPeerCount,
    required this.onlineFriendsCount,
  });
}

// ===== Scanning Actions =====

/// Scanning started
class ScanStartedAction extends AppAction {}

/// Scanning completed
class ScanCompletedAction extends AppAction {}
