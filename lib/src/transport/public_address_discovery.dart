import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'address_utils.dart';

/// Discovers our public-facing IP address and combines it with the local
/// UDP port to form the address we advertise to friends.
///
/// Tries IPv6 first (globally routable = well-connected). If IPv6 is
/// unavailable, falls back to IPv4 (NAT'd but hole-punchable). Never
/// advertises private LAN addresses — they are unreachable from outside.
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
  /// Tries IPv6 first (for well-connected / globally routable status).
  /// Falls back to IPv4 (NAT'd but hole-punchable via friends).
  /// Returns null only if both fail (no internet at all).
  ///
  /// Result is cached for [cacheDuration] to avoid excessive lookups.
  Future<InternetAddress?> discoverPublicIp() async {
    // Return cached value if fresh
    if (_cachedPublicIp != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < cacheDuration) {
      return _cachedPublicIp;
    }

    // Try IPv6 first — a globally routable IPv6 means we're well-connected.
    final ipv6 = await _fetchPublicIp('https://ipv6.seeip.org');
    if (ipv6 != null) {
      _cachedPublicIp = ipv6;
      _cacheTime = DateTime.now();
      debugPrint('Discovered public IPv6: ${ipv6.address}');
      return ipv6;
    }

    // Fall back to IPv4 — behind NAT but hole-punchable.
    final ipv4 = await _fetchPublicIp('https://ipv4.seeip.org');
    if (ipv4 != null) {
      _cachedPublicIp = ipv4;
      _cacheTime = DateTime.now();
      debugPrint('Discovered public IPv4: ${ipv4.address}');
      return ipv4;
    }

    debugPrint('Public IP discovery failed for both IPv6 and IPv4');
    return null;
  }

  /// Fetch our public IP from the given URL.
  Future<InternetAddress?> _fetchPublicIp(String url) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final ip = body.trim();

        if (ip.isEmpty) {
          debugPrint('Empty response from $url');
          return null;
        }

        final parsed = InternetAddress.tryParse(ip);
        if (parsed == null) {
          debugPrint('Failed to parse IP from $url: $ip');
          return null;
        }

        return parsed;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('IP discovery from $url failed: $e');
      return null;
    }
  }

  /// Get our public address string (public_ip:local_port).
  ///
  /// Combines the discovered public IP with the given local port.
  /// For IPv4, assumes the NAT preserves the port (cone NAT).
  /// For IPv6, the address is globally routable and port is direct.
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
