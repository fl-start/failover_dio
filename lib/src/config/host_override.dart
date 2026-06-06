/// Per-host configuration overlay used by `FailoverOptions.perHost`.
///
/// Only the fields explicitly set on a [HostOverride] take precedence;
/// every other field falls back to the global [FailoverOptions] value.
class HostOverride {
  /// Creates an override.
  const HostOverride({
    this.overallTimeout,
    this.maxIpAttempts,
    this.enableLatencyProbe,
    this.allowPrivateAddresses,
    this.enableFailoverHeaders,
    this.singleIpFastPath,
    this.latencyBucketMs,
    this.redirectToPeerStatus,
  });

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

  /// Latency quantisation bucket in milliseconds for ranking stability.
  ///
  /// Two IPs whose latency falls in the same bucket are treated as equal
  /// and will be randomly reordered for load distribution. `null` falls
  /// back to the global [FailoverOptions.latencyBucketMs].
  final int? latencyBucketMs;

  /// "Redirect-To-Peer" status code for this host.
  ///
  /// `null` falls back to [FailoverOptions.redirectToPeerStatus].
  /// Set to a specific value (e.g. `553`) to override the global setting
  /// for this host only.
  final int? redirectToPeerStatus;
}
