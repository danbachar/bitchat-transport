import 'dart:io';

import 'package:logger/logger.dart';
import 'package:public_ip_address/public_ip_address.dart';

import 'address_utils.dart';

/// Discovers our public-facing IP address and combines it with the local
/// UDP port to form the address we advertise to friends.
///
/// For peers behind NAT, the public IP differs from the local socket address.
/// We assume the NAT preserves the local port (cone NAT behavior), which is
/// true for most consumer routers. If port mapping differs, STUN can be used
/// in the future.
///
/// The discovered address is included in ANNOUNCE messages so friends know
/// where to send hole-punch packets and establish UDX connections.
class PublicAddressDiscovery {
  final Logger _log = Logger();

  /// Cached public IP (refreshed periodically)
  InternetAddress? _cachedPublicIp;

  /// When the cache was last refreshed
  DateTime? _cacheTime;

  /// Cache duration (public IP doesn't change often)
  static const Duration cacheDuration = Duration(minutes: 5);

  /// Discover our public IP address.
  ///
  /// Uses external service to determine the public-facing IP.
  /// Result is cached for [cacheDuration] to avoid excessive lookups.
  ///
  /// Returns null if discovery fails (no internet, service unavailable, etc).
  Future<InternetAddress?> discoverPublicIp() async {
    // Return cached value if fresh
    if (_cachedPublicIp != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < cacheDuration) {
      return _cachedPublicIp;
    }

    try {
      final ipService = IpAddress();
      final ip = await ipService.getIp();

      if (ip == null || ip.isEmpty) {
        _log.w('Public IP discovery returned empty result');
        return null;
      }

      final parsed = InternetAddress.tryParse(ip);
      if (parsed == null) {
        _log.w('Failed to parse public IP: $ip');
        return null;
      }

      _cachedPublicIp = parsed;
      _cacheTime = DateTime.now();
      _log.i('Discovered public IP: ${parsed.address}');
      return parsed;
    } catch (e) {
      _log.e('Public IP discovery failed: $e');
      return null;
    }
  }

  /// Get our public address string (public_ip:local_port).
  ///
  /// Combines the discovered public IP with the given local port.
  /// Assumes the NAT preserves the port (cone NAT).
  ///
  /// Returns null if public IP cannot be discovered.
  Future<String?> getPublicAddress(int localPort) async {
    final ip = await discoverPublicIp();
    if (ip == null) return null;
    return AddressInfo(ip, localPort).toAddressString();
  }

  /// Invalidate the cached public IP (e.g. on network change).
  void invalidateCache() {
    _cachedPublicIp = null;
    _cacheTime = null;
  }
}
