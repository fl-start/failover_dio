import 'dart:async';

/// A trivial "group" of in-flight futures keyed by a string.
///
/// First caller for a key starts the work; subsequent callers for the same
/// key wait on the same future. Used by the failover adapter to coalesce
/// concurrent cold-start attempts so an app launch doesn't fan out N TCP
/// connects to the same first IP.
class SingleFlight<T> {
  /// Creates an empty group.
  SingleFlight();

  final Map<String, Future<T>> _inflight = <String, Future<T>>{};

  /// Runs [body] under [key] if no other caller is already running it;
  /// otherwise awaits the existing future. Always cleans up on completion.
  Future<T> run(String key, Future<T> Function() body) {
    final Future<T>? existing = _inflight[key];
    if (existing != null) return existing;
    final Completer<T> c = Completer<T>();
    _inflight[key] = c.future;
    Future<T>(body).then<void>((T value) {
      _inflight.remove(key);
      if (!c.isCompleted) c.complete(value);
    }).catchError((Object e, StackTrace s) {
      _inflight.remove(key);
      if (!c.isCompleted) c.completeError(e, s);
    });
    return c.future;
  }

  /// Returns the number of currently in-flight keys.
  int get size => _inflight.length;
}
