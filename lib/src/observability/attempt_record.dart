/// Outcome of a single per-IP attempt within a logical fail-over request.
enum AttemptOutcome {
  /// Attempt produced an HTTP response (regardless of status code).
  succeeded,

  /// Attempt failed (timeout, connection error, TLS, etc.).
  failed,

  /// Attempt was aborted because another attempt won the race.
  abortedByWinner,

  /// Attempt was aborted because the caller cancelled the request.
  abortedByCancel,

  /// Attempt was abandoned because the overall timeout fired.
  abortedByOverallTimeout,
}

/// A timed record of one IP attempt, attached to `Response.extra` and to
/// `FailoverExhaustedError.attempts`.
class AttemptRecord {
  /// Creates a record.
  const AttemptRecord({
    required this.attemptIndex,
    required this.ip,
    required this.outcome,
    required this.durationMs,
    this.statusCode,
    this.error,
  });

  /// Zero-based attempt index (0 = the original request, 1+ = fallbacks).
  final int attemptIndex;

  /// String form of the IP address the attempt targeted.
  final String ip;

  /// What ultimately happened with this attempt.
  final AttemptOutcome outcome;

  /// Wall-clock duration of the attempt in milliseconds.
  final int durationMs;

  /// HTTP status code, when [outcome] is [AttemptOutcome.succeeded].
  final int? statusCode;

  /// Error object captured when [outcome] is [AttemptOutcome.failed].
  final Object? error;

  @override
  String toString() {
    final StringBuffer b = StringBuffer('AttemptRecord(')
      ..write('attempt=$attemptIndex,')
      ..write(' ip=$ip,')
      ..write(' outcome=${outcome.name},')
      ..write(' ms=$durationMs');
    if (statusCode != null) b.write(', status=$statusCode');
    if (error != null) b.write(', error=$error');
    b.write(')');
    return b.toString();
  }
}
