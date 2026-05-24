import 'dns_resolver.dart';

/// **Phase 2 placeholder** for a DNS-over-HTTPS resolver.
///
/// The interface is provided now so users can substitute a real DoH
/// implementation (Cloudflare/Google/Quad9) at any time via
/// `FailoverOptions.dnsResolver` without changing call-sites. A built-in
/// implementation will land in a follow-up release.
///
/// Calling [resolve] on this stub throws `UnimplementedError`.
class DohResolver implements DnsResolver {
  /// Creates the stub.
  const DohResolver({this.provider = 'cloudflare'});

  /// DoH provider hint (`cloudflare`, `google`, `quad9`, ...).
  final String provider;

  @override
  Future<DnsAnswer> resolve(String host) {
    throw UnimplementedError(
      'DohResolver is a placeholder in failover_dio v0.1. '
      'Supply your own DnsResolver implementation via FailoverOptions.dnsResolver.',
    );
  }
}
