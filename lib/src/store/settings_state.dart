import 'package:flutter/foundation.dart';

/// Available transport protocols
enum TransportProtocol {
  bluetooth,
  iroh,
}

/// Extension for display info
extension TransportProtocolDisplay on TransportProtocol {
  String get displayName {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Bluetooth';
      case TransportProtocol.iroh:
        return 'Internet (iroh)';
    }
  }

  String get description {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Connect to nearby peers via Bluetooth Low Energy';
      case TransportProtocol.iroh:
        return 'Connect to peers over the Internet via iroh';
    }
  }
}

/// Immutable transport settings for Redux store
@immutable
class SettingsState {
  /// Whether Bluetooth transport is enabled
  final bool bluetoothEnabled;

  /// Whether iroh Internet transport is enabled
  final bool irohEnabled;

  /// Priority order for transports (lower index = higher priority)
  /// Default: Bluetooth first, then iroh
  final List<TransportProtocol> transportPriority;

  const SettingsState({
    this.bluetoothEnabled = true,
    this.irohEnabled = true,
    this.transportPriority = const [
      TransportProtocol.bluetooth,
      TransportProtocol.iroh,
    ],
  });

  static const SettingsState initial = SettingsState();

  /// Whether at least one transport is enabled
  bool get hasActiveTransport => bluetoothEnabled || irohEnabled;

  /// Get the preferred transport for sending messages
  TransportProtocol? get preferredTransport {
    for (final transport in transportPriority) {
      if (transport == TransportProtocol.bluetooth && bluetoothEnabled) {
        return TransportProtocol.bluetooth;
      }
      if (transport == TransportProtocol.iroh && irohEnabled) {
        return TransportProtocol.iroh;
      }
    }
    return null;
  }

  SettingsState copyWith({
    bool? bluetoothEnabled,
    bool? irohEnabled,
    List<TransportProtocol>? transportPriority,
  }) {
    return SettingsState(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      irohEnabled: irohEnabled ?? this.irohEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
    );
  }

  Map<String, dynamic> toJson() => {
        'bluetoothEnabled': bluetoothEnabled,
        'irohEnabled': irohEnabled,
        'transportPriority': transportPriority.map((t) => t.name).toList(),
      };

  factory SettingsState.fromJson(Map<String, dynamic> json) {
    return SettingsState(
      bluetoothEnabled: json['bluetoothEnabled'] as bool? ?? true,
      irohEnabled: json['irohEnabled'] as bool? ?? true,
      transportPriority: (json['transportPriority'] as List<dynamic>?)
              ?.map((e) => TransportProtocol.values.firstWhere(
                    (t) => t.name == e,
                    orElse: () => TransportProtocol.bluetooth,
                  ))
              .toList() ??
          const [TransportProtocol.bluetooth, TransportProtocol.iroh],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsState &&
          runtimeType == other.runtimeType &&
          bluetoothEnabled == other.bluetoothEnabled &&
          irohEnabled == other.irohEnabled &&
          listEquals(transportPriority, other.transportPriority);

  @override
  int get hashCode => Object.hash(
        bluetoothEnabled,
        irohEnabled,
        Object.hashAll(transportPriority),
      );

  @override
  String toString() =>
      'SettingsState(bt: $bluetoothEnabled, iroh: $irohEnabled)';
}
