import '../observability/attempt_record.dart';

/// Structured error attached to `DioException.error` when a logical request
/// is exhausted (all IPs failed within the `maxIpAttempts` ceiling, or the
/// overall timeout fired).
///
/// Use `e.toString()` for a debuggable summary.
class FailoverExhaustedError {
  /// Creates the error.
  const FailoverExhaustedError({
    required this.host,
    required this.attempts,
    required this.idempotencyKey,
    required this.overallDurationMs,
    this.reason = 'all_attempts_failed',
  });

  /// Normalized hostname that was being resolved.
  final String host;

  /// Per-attempt records (ordered by attempt index).
  final List<AttemptRecord> attempts;

  /// Idempotency key that was used across attempts (server-side correlation).
  final String idempotencyKey;

  /// Wall-clock duration of the whole logical request in ms.
  final int overallDurationMs;

  /// `all_attempts_failed`, `overall_timeout`, or another short tag.
  final String reason;

  @override
  String toString() {
    final StringBuffer b = StringBuffer('FailoverExhaustedError(')
      ..writeln('host=$host,')
      ..writeln('  reason=$reason,')
      ..writeln('  overallMs=$overallDurationMs,')
      ..writeln('  idempotencyKey=$idempotencyKey,')
      ..writeln('  attempts=[');
    for (final AttemptRecord a in attempts) {
      b.writeln('    $a,');
    }
    b.write('  ])');
    return b.toString();
  }
}
