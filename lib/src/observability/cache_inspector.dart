/// Immutable snapshot of a single host's cache state.
class HostSnapshot {
  /// Creates a snapshot.
  const HostSnapshot({
    required this.host,
    required this.ips,
    required this.latencyMs,
    required this.unavailableUntil,
    required this.ttlRemainingMs,
    required this.lastResolvedAt,
    required this.lastAccessedAt,
  });

  /// Normalized hostname.
  final String host;

  /// Cached IPs in latency-sorted order.
  final List<String> ips;

  /// Per-IP measured latency in ms; `null` if not yet probed.
  final Map<String, int?> latencyMs;

  /// Per-IP unavailability expiry; `null` if currently available.
  final Map<String, DateTime?> unavailableUntil;

  /// Remaining TTL on the freshest entry, in ms.
  final int ttlRemainingMs;

  /// Wall-clock time the host was most recently resolved via DNS.
  final DateTime lastResolvedAt;

  /// Wall-clock time the host's cache entry was most recently read.
  final DateTime lastAccessedAt;

  @override
  String toString() {
    final StringBuffer b = StringBuffer('HostSnapshot($host:\n')
      ..writeln('  ips=$ips')
      ..writeln('  latencyMs=$latencyMs')
      ..writeln('  unavailableUntil=$unavailableUntil')
      ..writeln('  ttlRemainingMs=$ttlRemainingMs')
      ..writeln('  lastResolvedAt=$lastResolvedAt')
      ..write('  lastAccessedAt=$lastAccessedAt)');
    return b.toString();
  }
}

/// Immutable snapshot of the entire cache.
class CacheSnapshot {
  /// Creates a snapshot.
  const CacheSnapshot({required this.hosts});

  /// All known hosts, keyed by normalized hostname.
  final Map<String, HostSnapshot> hosts;

  /// Number of cached hosts.
  int get size => hosts.length;

  @override
  String toString() {
    if (hosts.isEmpty) return 'CacheSnapshot(empty)';
    final StringBuffer b = StringBuffer('CacheSnapshot(${hosts.length} hosts):\n');
    for (final HostSnapshot h in hosts.values) {
      b
        ..writeln(h.toString())
        ..writeln();
    }
    return b.toString();
  }
}
