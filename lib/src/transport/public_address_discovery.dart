import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'address_utils.dart';

/// Discovers our public-facing UDP address and combines it with the local
/// UDP port to form the address we advertise to friends.
///
/// The transport is IPv6-only: if the device has no public IPv6, we treat
/// it as "no Internet" for our purposes. The discovered address is included
/// in ANNOUNCE messages so peers and rendezvous servers know where to reach
/// us.
class PublicAddressDiscovery {
  /// Cached public IPv6 (refreshed periodically).
  InternetAddress? _cachedPublicIp;

  /// When the cache was last refreshed.
  DateTime? _cacheTime;

  /// Cache duration (public IP doesn't change often).
  static const Duration cacheDuration = Duration(minutes: 5);

  /// The best public IPv6 we know of — also exposed for UI purposes on
  /// devices that can't actually use UDP to the open Internet.
  InternetAddress? get bestPublicIp => _cachedPublicIp;

  /// Discover our public IPv6 address.
  ///
  /// Returns null if the device has no IPv6 route at all — IPv4 is
  /// intentionally not queried. Result is cached for [cacheDuration] to
  /// avoid excessive lookups.
  Future<InternetAddress?> discoverPublicIp() async {
    if (_cachedPublicIp != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < cacheDuration) {
      return _cachedPublicIp;
    }

    final discovered = await _fetchPublicIp('https://ipv6.seeip.org');
    if (discovered == null || discovered.type != InternetAddressType.IPv6) {
      debugPrint('No public IPv6 address available for UDP transport');
      return null;
    }

    _cachedPublicIp = discovered;
    _cacheTime = DateTime.now();
    debugPrint('Discovered public IPv6: ${discovered.address}');
    return discovered;
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

  /// Get our public address string `[ipv6]:port`.
  ///
  /// Returns null if no public IPv6 is available.
  Future<String?> getPublicAddress(int localPort) async {
    final ip = await discoverPublicIp();
    if (ip == null) return null;
    return AddressInfo(ip, localPort).toAddressString();
  }

  /// Discover our link-local IPv6 address from network interfaces.
  ///
  /// Link-local addresses (fe80::) work on the same L2 segment and can
  /// bypass WiFi AP client isolation that blocks global IPv6 traffic.
  /// Returns the address as `[fe80::...%iface]:port` ready for use, or
  /// null if no link-local IPv6 interface is found.
  Future<String?> getLinkLocalAddress(int localPort) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLinkLocal) {
            final llAddr = AddressInfo(addr, localPort).toAddressString();
            debugPrint(
                'Discovered link-local IPv6: ${addr.address} on ${iface.name}');
            return llAddr;
          }
        }
      }
    } catch (e) {
      debugPrint('Link-local discovery failed: $e');
    }
    return null;
  }

  /// Invalidate the cached public IP (e.g. on network change).
  void invalidateCache() {
    _cachedPublicIp = null;
    _cacheTime = null;
  }
}
