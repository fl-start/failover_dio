/// Holder for per-host SPKI SHA-256 certificate pins.
///
/// This class stores the pin configuration so it can be validated when
/// supported. **Enforcement is a no-op stub in v0.1**: dart:io's
/// `connectionFactory` path does not currently surface the certificate
/// before the HTTP request is sent, so wiring pins into `SecureSocket` is
/// deferred to a follow-up release. The configuration is preserved so users
/// can set it now without code changes when enforcement lands.
class CertificatePinner {
  /// Creates a pinner with the given per-host pin sets.
  ///
  /// Each pin should be the `sha256/<base64>` form of the SPKI hash.
  const CertificatePinner(this.pinsByHost);

  /// Empty pinner (no enforcement).
  factory CertificatePinner.empty() =>
      const CertificatePinner(<String, List<String>>{});

  /// Pins keyed by normalized hostname.
  final Map<String, List<String>> pinsByHost;

  /// Returns `true` if pin validation is configured for [host].
  bool hasPinsFor(String host) =>
      pinsByHost.containsKey(host) && pinsByHost[host]!.isNotEmpty;

  /// Validates [actualSpkiSha256] (`sha256/<base64>`) against the configured
  /// pin set for [host]. Returns `true` when no pins are configured (no-op).
  ///
  /// **v0.1 stub**: returns `true` unconditionally. Logging of the requested
  /// validation will be added in a follow-up release.
  bool validate({required String host, required String actualSpkiSha256}) {
    final List<String>? pins = pinsByHost[host];
    if (pins == null || pins.isEmpty) return true;
    return pins.contains(actualSpkiSha256);
  }
}
