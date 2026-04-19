import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'address_utils.dart';

/// Discovers our public-facing UDP address and combines it with the local
/// UDP port to form the address we advertise to friends.
///
/// The transport operates on one IP family at a time. IPv6 is preferred when
/// available; otherwise we fall back to IPv4. The discovered address is
/// included in ANNOUNCE messages so peers and rendezvous servers know where to
/// reach us.
class PublicAddressDiscovery {
  /// Cached public IP (refreshed periodically)
  InternetAddress? _cachedPublicIp;
  InternetAddressType? _cachedPublicIpFamily;

  /// When the cache was last refreshed
  DateTime? _cacheTime;

  /// Cache duration (public IP doesn't change often)
  static const Duration cacheDuration = Duration(minutes: 5);

  /// The best public IP we know of (IPv6 preferred over IPv4).
  /// Set even when the address isn't globally routable for UDP — useful
  /// for display purposes on NAT'd devices.
  InternetAddress? _bestPublicIp;

  /// The best public IP discovered so far (IPv6 > IPv4).
  /// Available even when the device is behind NAT and has no open port.
  InternetAddress? get bestPublicIp => _bestPublicIp;

  /// Discover our public IP for the requested address family.
  ///
  /// Returns a public address of the requested family, or null if unavailable.
  ///
  /// Result is cached for [cacheDuration] to avoid excessive lookups.
  Future<InternetAddress?> discoverPublicIp({
    InternetAddressType preferredFamily = InternetAddressType.IPv6,
  }) async {
    // Return cached value if fresh
    if (_cachedPublicIp != null &&
        _cachedPublicIpFamily == preferredFamily &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < cacheDuration) {
      return _cachedPublicIp;
    }

    Future<InternetAddress?> discoverFamily(InternetAddressType family) async {
      final url = family == InternetAddressType.IPv6
          ? 'https://ipv6.seeip.org'
          : 'https://api.seeip.org';
      final discovered = await _fetchPublicIp(url);
      if (discovered == null || discovered.type != family) {
        return null;
      }
      return discovered;
    }

    final preferred = await discoverFamily(preferredFamily);
    if (preferred != null) {
      _cachedPublicIp = preferred;
      _cachedPublicIpFamily = preferredFamily;
      _cacheTime = DateTime.now();
      if (_bestPublicIp == null ||
          preferred.type == InternetAddressType.IPv6 ||
          _bestPublicIp!.type != InternetAddressType.IPv6) {
        _bestPublicIp = preferred;
      }
      debugPrint(
          'Discovered public ${preferredFamily == InternetAddressType.IPv6 ? "IPv6" : "IPv4"}: '
          '${preferred.address}');
      return preferred;
    }

    final alternateFamily = preferredFamily == InternetAddressType.IPv6
        ? InternetAddressType.IPv4
        : InternetAddressType.IPv6;
    final alternate = await discoverFamily(alternateFamily);
    if (alternate != null &&
        (_bestPublicIp == null ||
            alternate.type == InternetAddressType.IPv6 ||
            _bestPublicIp!.type != InternetAddressType.IPv6)) {
      _bestPublicIp = alternate;
    }

    debugPrint(
      'No public ${preferredFamily == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
      'address available for UDP transport',
    );
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
  /// Combines the discovered public IP for the requested family with the given
  /// local port. Returns null if no matching public IP is available.
  Future<String?> getPublicAddress(
    int localPort, {
    required InternetAddressType family,
  }) async {
    final ip = await discoverPublicIp(preferredFamily: family);
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
            // Link-local addresses need a scope/zone ID for socket ops.
            // Dart's InternetAddress.address includes it (e.g. fe80::1%wlan0).
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
    _cachedPublicIpFamily = null;
    _cacheTime = null;
    _bestPublicIp = null;
  }
}
