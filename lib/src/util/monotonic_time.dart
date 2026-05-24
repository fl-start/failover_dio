/// A monotonic time source for clock-skew safe TTL math.
///
/// Wall-clock [DateTime.now] can jump forward or backward due to NTP
/// adjustments or device sleep. The library uses monotonic time for
/// expiry comparisons to avoid spurious cache misses or eternal caches.
class MonotonicTime {
  MonotonicTime._();

  static final Stopwatch _stopwatch = Stopwatch()..start();

  /// Returns elapsed microseconds since process start. Monotonic; never
  /// decreases.
  static int nowMicros() => _stopwatch.elapsedMicroseconds;

  /// Returns elapsed [Duration] since process start.
  static Duration now() => Duration(microseconds: nowMicros());
}
