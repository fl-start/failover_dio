import 'dart:io';

/// Validates resolved [InternetAddress]es to drop unsafe or unusable
/// addresses before they are inserted into the failover cache.
///
/// This is an SSRF safety net: even if a DNS resolver is compromised or
/// misconfigured, the library will not connect to obviously dangerous
/// targets (`0.0.0.0`, loopback for public hosts, link-local, multicast).
class AddressValidator {
  /// Creates a validator with the given policies.
  ///
  /// [allowPrivate] controls whether RFC1918 IPv4 ranges and ULA IPv6
  /// (`fc00::/7`) addresses are permitted for public hosts.
  ///
  /// [localHosts] is a set of normalized hostnames for which loopback /
  /// link-local / private addresses should always be allowed (e.g.
  /// `localhost`, hosts ending in `.local`).
  const AddressValidator({
    this.allowPrivate = true,
    this.localHosts = const {'localhost'},
  });

  /// Whether private (RFC1918, ULA) IPs are allowed for non-local hosts.
  final bool allowPrivate;

  /// Hosts for which any address (including loopback/private) is allowed.
  final Set<String> localHosts;

  /// Returns `true` if [address] is safe to add to the cache for [host].
  ///
  /// [host] should be a normalized hostname (see `HostnameNormalizer`).
  bool isAllowed(InternetAddress address, String host) {
    final bool isLocalHost = _isLocalHost(host);

    // Always reject unspecified, multicast, and broadcast.
    if (_isUnspecified(address)) return false;
    if (address.isMulticast) return false;
    if (_isBroadcast(address)) return false;

    // Link-local (169.254.0.0/16 and fe80::/10) — never useful for normal HTTP.
    if (address.isLinkLocal && !isLocalHost) return false;

    // Loopback — only allow for local hosts.
    if (address.isLoopback && !isLocalHost) return false;

    // Private ranges — controlled by [allowPrivate], always allowed for local.
    if (!isLocalHost && !allowPrivate && _isPrivate(address)) return false;

    return true;
  }

  bool _isLocalHost(String host) {
    if (localHosts.contains(host)) return true;
    if (host.endsWith('.local')) return true;
    return false;
  }

  bool _isUnspecified(InternetAddress a) {
    if (a.type == InternetAddressType.IPv4) {
      return a.address == '0.0.0.0';
    }
    return a.address == '::' || a.address == '::0';
  }

  bool _isBroadcast(InternetAddress a) {
    return a.type == InternetAddressType.IPv4 && a.address == '255.255.255.255';
  }

  bool _isPrivate(InternetAddress a) {
    if (a.type == InternetAddressType.IPv4) {
      final List<int> parts = a.rawAddress;
      if (parts.length != 4) return false;
      final int o0 = parts[0];
      final int o1 = parts[1];
      // 10.0.0.0/8
      if (o0 == 10) return true;
      // 172.16.0.0/12
      if (o0 == 172 && o1 >= 16 && o1 <= 31) return true;
      // 192.168.0.0/16
      if (o0 == 192 && o1 == 168) return true;
      return false;
    }
    // IPv6 ULA: fc00::/7 (first 7 bits == 1111110).
    final List<int> bytes = a.rawAddress;
    if (bytes.isEmpty) return false;
    return (bytes[0] & 0xFE) == 0xFC;
  }
}
