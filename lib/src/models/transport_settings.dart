import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings for transport layer protocols
class TransportSettings {
  /// Whether Bluetooth transport is enabled
  final bool bluetoothEnabled;

  /// Whether libp2p Internet transport is enabled
  final bool libp2pEnabled;

  /// Priority order for transports (lower index = higher priority)
  /// Default: Bluetooth first, then libp2p
  final List<TransportProtocol> transportPriority;

  const TransportSettings({
    this.bluetoothEnabled = true,
    this.libp2pEnabled = true,
    this.transportPriority = const [
      TransportProtocol.bluetooth,
      TransportProtocol.libp2p,
    ],
  });

  /// Whether at least one transport is enabled
  bool get hasActiveTransport => bluetoothEnabled || libp2pEnabled;

  /// Get the preferred transport for sending messages
  TransportProtocol? get preferredTransport {
    for (final transport in transportPriority) {
      if (transport == TransportProtocol.bluetooth && bluetoothEnabled) {
        return TransportProtocol.bluetooth;
      }
      if (transport == TransportProtocol.libp2p && libp2pEnabled) {
        return TransportProtocol.libp2p;
      }
    }
    return null;
  }

  TransportSettings copyWith({
    bool? bluetoothEnabled,
    bool? libp2pEnabled,
    List<TransportProtocol>? transportPriority,
  }) {
    return TransportSettings(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      libp2pEnabled: libp2pEnabled ?? this.libp2pEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
    );
  }

  Map<String, dynamic> toJson() => {
        'bluetoothEnabled': bluetoothEnabled,
        'libp2pEnabled': libp2pEnabled,
        'transportPriority':
            transportPriority.map((t) => t.name).toList(),
      };

  factory TransportSettings.fromJson(Map<String, dynamic> json) {
    return TransportSettings(
      bluetoothEnabled: json['bluetoothEnabled'] ?? true,
      libp2pEnabled: json['libp2pEnabled'] ?? true,
      transportPriority: (json['transportPriority'] as List<dynamic>?)
              ?.map((e) => TransportProtocol.values.firstWhere(
                    (t) => t.name == e,
                    orElse: () => TransportProtocol.bluetooth,
                  ))
              .toList() ??
          const [TransportProtocol.bluetooth, TransportProtocol.libp2p],
    );
  }

  @override
  String toString() =>
      'TransportSettings(bt: $bluetoothEnabled, libp2p: $libp2pEnabled)';
}

/// Available transport protocols
enum TransportProtocol {
  bluetooth,
  libp2p,
}

/// Extension for display info
extension TransportProtocolDisplay on TransportProtocol {
  String get displayName {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Bluetooth';
      case TransportProtocol.libp2p:
        return 'Internet (libp2p)';
    }
  }

  String get description {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Connect to nearby peers via Bluetooth Low Energy';
      case TransportProtocol.libp2p:
        return 'Connect to peers over the Internet';
    }
  }
}

/// Store for transport settings with persistence
class TransportSettingsStore extends ChangeNotifier {
  static const String _storageKey = 'bitchat_transport_settings';

  TransportSettings _settings = const TransportSettings();

  /// Get current settings
  TransportSettings get settings => _settings;

  /// Whether Bluetooth is enabled
  bool get bluetoothEnabled => _settings.bluetoothEnabled;

  /// Whether libp2p is enabled
  bool get libp2pEnabled => _settings.libp2pEnabled;

  /// Initialize the store (load from storage)
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null) {
      try {
        final json = jsonDecode(data);
        _settings = TransportSettings.fromJson(json);
        notifyListeners();
      } catch (e) {
        debugPrint('Failed to load transport settings: $e');
      }
    }
  }

  /// Save to persistent storage
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_settings.toJson()));
  }

  /// Update Bluetooth enabled state
  Future<void> setBluetoothEnabled(bool enabled) async {
    if (_settings.bluetoothEnabled == enabled) return;
    _settings = _settings.copyWith(bluetoothEnabled: enabled);
    await _save();
    notifyListeners();
  }

  /// Update libp2p enabled state
  Future<void> setLibp2pEnabled(bool enabled) async {
    if (_settings.libp2pEnabled == enabled) return;
    _settings = _settings.copyWith(libp2pEnabled: enabled);
    await _save();
    notifyListeners();
  }

  /// Update both transport settings at once
  Future<void> updateSettings({
    bool? bluetoothEnabled,
    bool? libp2pEnabled,
  }) async {
    _settings = _settings.copyWith(
      bluetoothEnabled: bluetoothEnabled,
      libp2pEnabled: libp2pEnabled,
    );
    await _save();
    notifyListeners();
  }
}
