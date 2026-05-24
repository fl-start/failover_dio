/// A pluggable wall-clock abstraction.
///
/// Used for DNS TTL expiry, unavailability cooldown, and event timestamps.
/// Tests can substitute a [Clock] that returns deterministic times.
abstract class Clock {
  /// Returns the current wall-clock time.
  DateTime now();
}

/// Default [Clock] implementation that delegates to `DateTime.now()`.
class SystemClock implements Clock {
  /// Creates a const [SystemClock].
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
