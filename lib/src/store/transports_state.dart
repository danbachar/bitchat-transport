import 'package:flutter/foundation.dart';
import '../transport/transport_service.dart';
import '../transport/address_utils.dart';

/// Per-transport lifecycle state for Redux store.
///
/// Tracks the lifecycle state of each transport independently,
/// replacing the old single global `TransportConnectionStatus`.
@immutable
class TransportsState {
  /// BLE transport lifecycle state
  final TransportState bleState;

  /// UDP transport lifecycle state
  final TransportState udpState;

  /// Error message for BLE transport (if in error state)
  final String? bleError;

  /// Error message for UDP transport (if in error state)
  final String? udpError;

  /// Whether BLE is currently scanning
  final bool bleScanning;

  /// Our discovered public UDP address (ip:port), null if not yet discovered
  final String? publicAddress;

  const TransportsState({
    this.bleState = TransportState.uninitialized,
    this.udpState = TransportState.uninitialized,
    this.bleError,
    this.udpError,
    this.bleScanning = false,
    this.publicAddress,
  });

  static const TransportsState initial = TransportsState();

  /// Whether any transport is active
  bool get isAnyActive =>
      bleState == TransportState.active ||
      udpState == TransportState.active;

  /// Whether the system is in a healthy state (any transport active)
  bool get isHealthy => isAnyActive;

  /// Whether this device is well-connected (has a globally routable public address).
  ///
  /// Well-connected devices can act as relay facilitators for friends behind NAT.
  bool get isWellConnected =>
      publicAddress != null && isGloballyRoutableAddress(publicAddress!);

  /// Overall status display string derived from per-transport states
  String get statusDisplayString {
    if (isAnyActive) {
      if (bleScanning) return 'Scanning for peers...';
      return 'Online';
    }
    if (bleState == TransportState.initializing ||
        udpState == TransportState.initializing) {
      return 'Starting...';
    }
    if (bleState == TransportState.ready ||
        udpState == TransportState.ready) {
      return 'Ready';
    }
    if (bleState == TransportState.error ||
        udpState == TransportState.error) {
      return bleError ?? udpError ?? 'Error';
    }
    return 'Initializing...';
  }

  TransportsState copyWith({
    TransportState? bleState,
    TransportState? udpState,
    String? bleError,
    String? udpError,
    bool? bleScanning,
    String? publicAddress,
  }) {
    return TransportsState(
      bleState: bleState ?? this.bleState,
      udpState: udpState ?? this.udpState,
      bleError: bleError ?? this.bleError,
      udpError: udpError ?? this.udpError,
      bleScanning: bleScanning ?? this.bleScanning,
      publicAddress: publicAddress ?? this.publicAddress,
    );
  }

  /// Create a copy with publicAddress explicitly cleared (set to null).
  TransportsState clearPublicAddress() {
    return TransportsState(
      bleState: bleState,
      udpState: udpState,
      bleError: bleError,
      udpError: udpError,
      bleScanning: bleScanning,
      publicAddress: null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportsState &&
          runtimeType == other.runtimeType &&
          bleState == other.bleState &&
          udpState == other.udpState &&
          bleError == other.bleError &&
          udpError == other.udpError &&
          bleScanning == other.bleScanning &&
          publicAddress == other.publicAddress;

  @override
  int get hashCode => Object.hash(
        bleState,
        udpState,
        bleError,
        udpError,
        bleScanning,
        publicAddress,
      );

  @override
  String toString() =>
      'TransportsState(ble: $bleState, udp: $udpState, scanning: $bleScanning, publicAddr: $publicAddress)';
}
