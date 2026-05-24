/// Constants for HTTP headers injected by the failover adapter.
///
/// Servers can read these to implement idempotent retry handling and
/// observability:
///
/// - [idempotencyKey] is constant across all IP attempts for a single
///   logical request, so servers can deduplicate.
/// - [previousIp] is **absent** on the first attempt and **present** on
///   fail-over attempts, allowing servers to distinguish initial vs retry
///   traffic without parsing.
class FailoverHeaders {
  FailoverHeaders._();

  /// Idempotency key (constant across attempts for one logical request).
  static const String idempotencyKey = 'failover_dio_idempotency_key';

  /// IP of the immediately preceding attempt that triggered this fail-over
  /// (absent on the first attempt).
  static const String previousIp = 'failover_dio_previous_ip';
}

/// `RequestOptions.extra` keys consumed and produced by the adapter.
class FailoverExtraKeys {
  FailoverExtraKeys._();

  /// Set to `true` on a request's `Options.extra` to bypass failover for
  /// that one request.
  static const String skip = 'failover_dio:skip';

  /// Per-request override for `FailoverOptions.maxIpAttempts`.
  static const String maxIpAttempts = 'failover_dio:max_ip_attempts';

  /// Per-request override for `FailoverOptions.overallTimeout` (a [Duration]).
  static const String overallTimeout = 'failover_dio:overall_timeout';

  /// Per-request override of the whole [FailoverOptions] instance.
  static const String options = 'failover_dio:options';

  // ===== Output keys (set by the adapter on Response.extra) =====

  /// Set to the IP string that produced the response.
  static const String winningIp = 'failover_dio:winning_ip';

  /// Set to `List<AttemptRecord>`.
  static const String attempts = 'failover_dio:attempts';

  /// Set to the idempotency key used.
  static const String idempotencyKey = 'failover_dio:idempotency_key';

  /// Set to total ms from `fetch` entry to response.
  static const String totalMs = 'failover_dio:total_ms';
}
