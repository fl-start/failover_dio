import 'dart:collection';

/// Tracks LRU recency for arbitrary keys.
///
/// The cache calls [touch] on every read or write; [evictionCandidate]
/// returns the least-recently-used key when the cache exceeds its size cap.
class LruTracker<K> {
  /// Creates an LRU tracker with [maxSize] capacity.
  LruTracker(this.maxSize);

  /// Maximum number of tracked keys before eviction.
  final int maxSize;

  // Use insertion-ordered map; removing then re-inserting moves a key to MRU.
  final LinkedHashMap<K, int> _recency = LinkedHashMap<K, int>();
  int _seq = 0;

  /// Marks [key] as most recently used.
  void touch(K key) {
    _recency.remove(key);
    _recency[key] = _seq++;
  }

  /// Stops tracking [key].
  void forget(K key) => _recency.remove(key);

  /// Returns `true` if the tracker is over capacity.
  bool isOverCapacity() => _recency.length > maxSize;

  /// Returns the least-recently-used key, or `null` if empty.
  K? evictionCandidate() => _recency.isEmpty ? null : _recency.keys.first;

  /// Current size.
  int get size => _recency.length;
}
