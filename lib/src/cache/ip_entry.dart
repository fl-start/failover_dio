import 'dart:io';

/// One cached IP for a given host.
///
/// Mutable in-place: latency and unavailability are updated by the cache,
/// not replaced.
class IpEntry {
  /// Creates an entry.
  IpEntry({
    required this.address,
    required this.ttlSeconds,
    required this.expiresAtMicros,
    this.dnsOrder = 0,
    this.latencyMs,
    this.unavailableUntil,
    this.consecutiveFailures = 0,
    this.lastProbedAt,
  });

  /// Original position in the DNS answer (lower = earlier). Used as a
  /// tie-breaker so order is deterministic when latencies are equal or
  /// unknown.
  final int dnsOrder;

  /// IP address (`InternetAddress.IPv4` or `InternetAddress.IPv6`).
  final InternetAddress address;

  /// Original TTL from the DNS answer.
  final int ttlSeconds;

  /// Monotonic microsecond timestamp at which this entry expires.
  int expiresAtMicros;

  /// Last measured latency in ms; `null` if not yet probed.
  int? latencyMs;

  /// Until when (wall-clock) this IP is unavailable; `null` when available.
  DateTime? unavailableUntil;

  /// Consecutive failure count used to compute exponential cooldown.
  int consecutiveFailures;

  /// Wall-clock time of the most recent probe (used for dedup).
  DateTime? lastProbedAt;

  /// String form of the IP for logging and headers.
  String get addressString => address.address;

  /// Returns `true` if this entry is currently marked unavailable per
  /// [now]'s wall clock.
  bool isUnavailable(DateTime now) {
    final DateTime? u = unavailableUntil;
    return u != null && u.isAfter(now);
  }

  /// Returns `true` if [nowMicros] is past [expiresAtMicros].
  bool isExpired(int nowMicros) => nowMicros >= expiresAtMicros;
}
