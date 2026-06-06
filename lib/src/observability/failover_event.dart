import 'attempt_record.dart';

/// Base type for all events emitted on the `FailoverDio.events` stream.
///
/// Events are strongly typed so consumers can pattern-match using Dart's
/// sealed-class exhaustiveness checking.
sealed class FailoverEvent {
  /// Creates an event timestamped at construction.
  FailoverEvent() : timestamp = DateTime.now();

  /// Wall-clock time the event was created.
  final DateTime timestamp;
}

/// DNS resolution succeeded for [host].
final class HostResolved extends FailoverEvent {
  /// Creates the event.
  HostResolved({
    required this.host,
    required this.ips,
    required this.ttl,
    required this.durationMs,
  });

  /// Normalized hostname.
  final String host;

  /// String form of each resolved IP, in DNS answer order.
  final List<String> ips;

  /// Duration the DNS layer reported for this answer (smallest TTL).
  final Duration ttl;

  /// Wall-clock duration of the lookup.
  final int durationMs;
}

/// A latency probe finished against a single IP.
final class LatencyProbed extends FailoverEvent {
  /// Creates the event.
  LatencyProbed({
    required this.host,
    required this.ip,
    required this.latencyMs,
    required this.success,
    this.completionOrder,
  });

  /// Normalized hostname the IP belongs to.
  final String host;

  /// String form of the IP that was probed.
  final String ip;

  /// Measured latency in ms, or `null` if the probe failed/timed out.
  final int? latencyMs;

  /// Whether the probe completed within the budget.
  final bool success;

  /// Finish order in the Happy Eyeballs parallel race (0 = first arrival).
  ///
  /// `null` when the probe was not part of a parallel race (legacy path).
  final int? completionOrder;
}

/// A per-IP HTTP attempt started.
final class AttemptStarted extends FailoverEvent {
  /// Creates the event.
  AttemptStarted({
    required this.host,
    required this.ip,
    required this.attemptIndex,
    required this.idempotencyKey,
    this.previousIp,
  });

  /// Normalized hostname.
  final String host;

  /// String form of the IP being attempted.
  final String ip;

  /// Zero-based attempt index.
  final int attemptIndex;

  /// Stable per-request idempotency key sent as
  /// `failover_dio_idempotency_key`.
  final String idempotencyKey;

  /// IP of the immediately preceding (timed-out) attempt, or `null` for the
  /// first attempt.
  final String? previousIp;
}

/// A per-IP HTTP attempt produced a response (any status code).
final class AttemptSucceeded extends FailoverEvent {
  /// Creates the event.
  AttemptSucceeded({
    required this.host,
    required this.ip,
    required this.attemptIndex,
    required this.statusCode,
    required this.durationMs,
  });

  /// Normalized hostname.
  final String host;

  /// String form of the IP that produced the response.
  final String ip;

  /// Attempt index.
  final int attemptIndex;

  /// HTTP status code.
  final int statusCode;

  /// Duration in ms from attempt start to response received.
  final int durationMs;
}

/// A per-IP HTTP attempt was aborted internally (winner selected, cancel, or
/// overall-timeout exhaustion).
final class AttemptAborted extends FailoverEvent {
  /// Creates the event.
  AttemptAborted({
    required this.host,
    required this.ip,
    required this.attemptIndex,
    required this.reason,
  });

  /// Normalized hostname.
  final String host;

  /// String form of the IP.
  final String ip;

  /// Attempt index.
  final int attemptIndex;

  /// Why the attempt was aborted.
  final AttemptOutcome reason;
}

/// A per-IP HTTP attempt failed with an error.
final class AttemptFailed extends FailoverEvent {
  /// Creates the event.
  AttemptFailed({
    required this.host,
    required this.ip,
    required this.attemptIndex,
    required this.error,
    required this.durationMs,
  });

  /// Normalized hostname.
  final String host;

  /// String form of the IP.
  final String ip;

  /// Attempt index.
  final int attemptIndex;

  /// Error object thrown by the underlying transport.
  final Object error;

  /// Time from attempt start to failure in ms.
  final int durationMs;
}

/// An IP was marked temporarily unavailable.
final class IpMarkedUnavailable extends FailoverEvent {
  /// Creates the event.
  IpMarkedUnavailable({
    required this.host,
    required this.ip,
    required this.until,
  });

  /// Normalized hostname.
  final String host;

  /// String form of the IP.
  final String ip;

  /// Wall-clock time when the IP becomes eligible again.
  final DateTime until;
}

/// A host's cached IP list was refreshed via re-resolution.
final class CacheRefreshed extends FailoverEvent {
  /// Creates the event.
  CacheRefreshed({
    required this.host,
    required this.ipsBefore,
    required this.ipsAfter,
  });

  /// Normalized hostname.
  final String host;

  /// IPs cached before the refresh.
  final List<String> ipsBefore;

  /// IPs cached after the refresh.
  final List<String> ipsAfter;
}

/// A cache entry was evicted (TTL expiry, LRU pressure, or explicit clear).
final class CacheEvicted extends FailoverEvent {
  /// Creates the event.
  CacheEvicted({required this.host, required this.reason});

  /// Normalized hostname.
  final String host;

  /// Human-readable reason: `lru`, `expired`, `explicit`.
  final String reason;
}

/// All eligible IPs failed; the logical request is about to throw.
final class RequestExhausted extends FailoverEvent {
  /// Creates the event.
  RequestExhausted({
    required this.host,
    required this.attempts,
    required this.idempotencyKey,
  });

  /// Normalized hostname.
  final String host;

  /// Records of every IP attempt for this logical request.
  final List<AttemptRecord> attempts;

  /// The idempotency key that was used across all attempts.
  final String idempotencyKey;
}
