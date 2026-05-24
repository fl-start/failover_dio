import 'dart:io';

/// Result of a DNS resolution.
class DnsAnswer {
  /// Creates a DNS answer.
  const DnsAnswer({required this.addresses, required this.ttl});

  /// Resolved addresses in answer order (caller may re-sort by latency).
  final List<InternetAddress> addresses;

  /// Smallest TTL among the records returned. The cache uses this as the
  /// freshness bound for the whole answer.
  final Duration ttl;

  /// Convenience accessor: `true` when [addresses] is empty.
  bool get isEmpty => addresses.isEmpty;
}

/// Pluggable DNS resolver interface.
///
/// The default implementation ([PlatformDnsResolver]) uses
/// `InternetAddress.lookup`, which honors the operating system's resolver
/// (including `/etc/hosts`, captive-portal redirection, VPN split-DNS, and
/// platform DoH where available). Because the platform call does not expose
/// per-record TTL, the default implementation reports a configurable fixed
/// TTL.
///
/// Users wanting genuine per-record TTL or DoH support can supply a custom
/// implementation via `FailoverOptions.dnsResolver`.
abstract class DnsResolver {
  /// Resolves [host] and returns A + AAAA addresses with a TTL hint.
  ///
  /// Implementations should throw on failure; the cache layer translates
  /// thrown errors into a negative cache entry.
  Future<DnsAnswer> resolve(String host);
}

/// Default resolver built on `InternetAddress.lookup`.
///
/// Because the platform call does not surface TTL, this implementation
/// returns a fixed [defaultTtl] (default 60s). This is a deliberate
/// trade-off for portability; pluggable resolvers can supply real TTL.
class PlatformDnsResolver implements DnsResolver {
  /// Creates a platform resolver.
  const PlatformDnsResolver({
    this.defaultTtl = const Duration(seconds: 60),
    this.lookupTimeout = const Duration(seconds: 5),
  });

  /// TTL reported for every resolved answer.
  final Duration defaultTtl;

  /// Maximum time to wait for the OS resolver before throwing.
  final Duration lookupTimeout;

  @override
  Future<DnsAnswer> resolve(String host) async {
    final List<InternetAddress> addrs =
        await InternetAddress.lookup(host).timeout(lookupTimeout);
    return DnsAnswer(addresses: addrs, ttl: defaultTtl);
  }
}
