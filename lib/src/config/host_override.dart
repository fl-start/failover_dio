/// Per-host configuration overlay used by `FailoverOptions.perHost`.
///
/// Only the fields explicitly set on a [HostOverride] take precedence;
/// every other field falls back to the global [FailoverOptions] value.
class HostOverride {
  /// Creates an override.
  const HostOverride({
    this.getConnectTimeout,
    this.defaultConnectTimeout,
    this.overallTimeout,
    this.maxIpAttempts,
    this.enableLatencyProbe,
    this.allowPrivateAddresses,
    this.enableFailoverHeaders,
    this.singleIpFastPath,
  });

  /// Fail-over trigger for GET/HEAD.
  final Duration? getConnectTimeout;

  /// Fail-over trigger for all other methods.
  final Duration? defaultConnectTimeout;

  /// Hard ceiling for the whole logical request.
  final Duration? overallTimeout;

  /// Maximum number of distinct IPs to attempt before failing.
  final int? maxIpAttempts;

  /// Whether to run TCP-connect latency probes for this host.
  final bool? enableLatencyProbe;

  /// Whether to allow private/RFC1918 addresses for this host.
  final bool? allowPrivateAddresses;

  /// Whether to inject `failover_dio_*` headers for this host.
  final bool? enableFailoverHeaders;

  /// Whether to route single-IP DNS results straight to the standard
  /// adapter (no instrumentation) for this host.
  final bool? singleIpFastPath;
}
