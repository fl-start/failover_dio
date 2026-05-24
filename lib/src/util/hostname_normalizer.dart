/// Normalizes hostnames for use as cache keys, per-host override lookups, and
/// bypass-list comparisons.
///
/// Normalization rules (matches RFC 4343 case-insensitivity and common
/// resolver behavior):
///
/// - Lowercases the entire hostname.
/// - Strips a single trailing dot (`example.com.` → `example.com`).
/// - Leaves IPv6 literals in URLs (`[::1]`) for the caller to detect; this
///   normalizer never converts an IP literal into a hostname.
///
/// IDN punycode encoding is delegated to the URI parser when the host is
/// produced from `Uri.parse`. Callers that pass raw user input should
/// pre-process through `Uri` first.
class HostnameNormalizer {
  const HostnameNormalizer._();

  /// Returns a normalized form of [host] suitable for cache keys and override
  /// matching.
  ///
  /// Returns the input unchanged if it is empty or appears to be an IPv6
  /// literal in bracket form.
  static String normalize(String host) {
    if (host.isEmpty) return host;
    var h = host;
    if (h.startsWith('[') && h.endsWith(']')) {
      // IPv6 literal; leave as-is (only inner bracket form gets here).
      return h.toLowerCase();
    }
    h = h.toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }
}
