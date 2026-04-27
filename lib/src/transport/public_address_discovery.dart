import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'address_utils.dart';

/// Discovers all UDP candidate addresses we can advertise to peers.
///
/// A "candidate" is any (ip, port) pair at which a peer might reach us:
/// - The public IPv6 from `https://ipv6.seeip.org`.
/// - The public IPv4 from `https://ipv4.seeip.org`.
/// - Every non-global local address (IPv6 link-local and ULA, IPv4
///   RFC1918 and 169.254/16) the kernel reports for our interfaces.
///
/// All discovered candidates are paired with our local UDP port and emitted
/// as `[ipv6]:port` / `ipv4:port` strings. The coordinator picks which port
/// to use (v6 vs v4 socket) when calling [discoverAllCandidates].
class PublicAddressDiscovery {
  InternetAddress? _cachedPublicV6;
  InternetAddress? _cachedPublicV4;
  DateTime? _cacheTime;

  /// Cache duration for public IP lookups (they change rarely).
  static const Duration cacheDuration = Duration(minutes: 5);

  /// Most recently discovered public IPv6, if any. Exposed for UI.
  InternetAddress? get bestPublicIpV6 => _cachedPublicV6;

  /// Most recently discovered public IPv4, if any. Exposed for UI.
  InternetAddress? get bestPublicIpV4 => _cachedPublicV4;

  /// Discover our public IPv6 address from `https://ipv6.seeip.org`.
  /// Returns null if no IPv6 path is available.
  Future<InternetAddress?> discoverPublicIpV6() async {
    if (_isCacheFresh() && _cachedPublicV6 != null) return _cachedPublicV6;

    final discovered = await _fetchPublicIp('https://ipv6.seeip.org');
    if (discovered == null || discovered.type != InternetAddressType.IPv6) {
      debugPrint('No public IPv6 address available');
      return null;
    }
    _cachedPublicV6 = discovered;
    _touchCache();
    debugPrint('Discovered public IPv6: ${discovered.address}');
    return discovered;
  }

  /// Discover our public IPv4 address from `https://ipv4.seeip.org`.
  /// Returns null if no IPv4 path is available.
  Future<InternetAddress?> discoverPublicIpV4() async {
    if (_isCacheFresh() && _cachedPublicV4 != null) return _cachedPublicV4;

    final discovered = await _fetchPublicIp('https://ipv4.seeip.org');
    if (discovered == null || discovered.type != InternetAddressType.IPv4) {
      debugPrint('No public IPv4 address available');
      return null;
    }
    _cachedPublicV4 = discovered;
    _touchCache();
    debugPrint('Discovered public IPv4: ${discovered.address}');
    return discovered;
  }

  bool _isCacheFresh() {
    if (_cacheTime == null) return false;
    return DateTime.now().difference(_cacheTime!) < cacheDuration;
  }

  void _touchCache() {
    _cacheTime ??= DateTime.now();
  }

  /// Enumerate every candidate address we can advertise.
  ///
  /// [localPortV6] is the port the IPv6 wildcard socket is bound to;
  /// [localPortV4] is the port the IPv4 wildcard socket is bound to. Pass
  /// null for either to skip candidates of that family.
  ///
  /// Output is sorted by priority (best first).
  Future<List<String>> discoverAllCandidates({
    int? localPortV6,
    int? localPortV4,
  }) async {
    final results = <String>[];

    final wantV6 = localPortV6 != null;
    final wantV4 = localPortV4 != null;

    // Public addresses (best-effort, parallel).
    final futures = <Future<void>>[];
    if (wantV6) {
      futures.add(discoverPublicIpV6().then((ip) {
        if (ip != null) {
          results.add(AddressInfo(ip, localPortV6).toAddressString());
        }
      }));
    }
    if (wantV4) {
      futures.add(discoverPublicIpV4().then((ip) {
        if (ip != null) {
          results.add(AddressInfo(ip, localPortV4).toAddressString());
        }
      }));
    }
    await Future.wait(futures);

    // Local interface enumeration: link-local + ULA (v6), RFC1918 +
    // 169.254/16 (v4). We skip global addresses found locally because the
    // public-IP lookup is the authoritative source for those (and avoids
    // advertising a globally routable LAN-side IP that might not survive
    // NAT in the way the kernel imagines).
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final cat = categorizeAddress(addr);
          switch (cat) {
            case AddressCategory.ipv6LinkLocal:
            case AddressCategory.ipv6UniqueLocal:
              if (wantV6) {
                results.add(AddressInfo(addr, localPortV6).toAddressString());
              }
              break;
            case AddressCategory.ipv4Private:
            case AddressCategory.ipv4LinkLocal:
              if (wantV4) {
                results.add(AddressInfo(addr, localPortV4).toAddressString());
              }
              break;
            case AddressCategory.ipv6Global:
            case AddressCategory.ipv4Global:
            case AddressCategory.other:
              break;
          }
        }
      }
    } catch (e) {
      debugPrint('Local interface enumeration failed: $e');
    }

    final deduped = <String>{...results}.toList();
    return sortCandidatesByPriority(deduped);
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
        if (ip.isEmpty) return null;
        return InternetAddress.tryParse(ip);
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('IP discovery from $url failed: $e');
      return null;
    }
  }

  /// Invalidate the cached public IPs (e.g. on network change).
  void invalidateCache() {
    _cachedPublicV6 = null;
    _cachedPublicV4 = null;
    _cacheTime = null;
  }
}
