import 'build_mode.dart';

/// Aggregated counters exposed via `FailoverDio.metrics()`.
///
/// In release mode the [noOp] singleton is used; reads return zeros and
/// increments are no-ops, so callers can always poll without conditionals
/// and the release build pays zero allocation cost.
abstract class FailoverMetrics {
  /// The active metrics singleton. Real counters in debug/profile,
  /// [NoOpFailoverMetrics] in release.
  static final FailoverMetrics instance =
      kReleaseMode ? const NoOpFailoverMetrics() : InMemoryFailoverMetrics();

  /// Total logical HTTP requests started.
  int get requestsTotal;

  /// Total fail-over attempts (count of distinct fallback IPs started).
  int get failoversTotal;

  /// Total DNS lookups that hit the network (cache misses).
  int get dnsLookupsTotal;

  /// Total cache lookups that hit fresh data.
  int get dnsCacheHits;

  /// Total cache misses.
  int get dnsCacheMisses;

  /// Total latency probes started.
  int get probesTotal;

  /// Total probes skipped due to recency dedup.
  int get probesDedupSkipped;

  /// Total LRU evictions.
  int get cacheEvictions;

  /// Increment helpers (no-ops in release).
  void incRequests();

  /// Records a fail-over event (fallback started).
  void incFailovers();

  /// Records a DNS lookup that hit the network.
  void incDnsLookups();

  /// Records a DNS cache hit.
  void incDnsCacheHits();

  /// Records a DNS cache miss.
  void incDnsCacheMisses();

  /// Records a latency probe started.
  void incProbes();

  /// Records a probe skipped due to dedup.
  void incProbesDedupSkipped();

  /// Records a cache eviction.
  void incCacheEvictions();

  /// Resets all counters to zero. Useful for tests.
  void reset();

  /// Returns a snapshot map of counter names to current values.
  Map<String, int> snapshot();
}

/// In-memory implementation used in debug and profile builds.
class InMemoryFailoverMetrics implements FailoverMetrics {
  int _requestsTotal = 0;
  int _failoversTotal = 0;
  int _dnsLookupsTotal = 0;
  int _dnsCacheHits = 0;
  int _dnsCacheMisses = 0;
  int _probesTotal = 0;
  int _probesDedupSkipped = 0;
  int _cacheEvictions = 0;

  @override
  int get requestsTotal => _requestsTotal;
  @override
  int get failoversTotal => _failoversTotal;
  @override
  int get dnsLookupsTotal => _dnsLookupsTotal;
  @override
  int get dnsCacheHits => _dnsCacheHits;
  @override
  int get dnsCacheMisses => _dnsCacheMisses;
  @override
  int get probesTotal => _probesTotal;
  @override
  int get probesDedupSkipped => _probesDedupSkipped;
  @override
  int get cacheEvictions => _cacheEvictions;

  @override
  void incRequests() => _requestsTotal++;
  @override
  void incFailovers() => _failoversTotal++;
  @override
  void incDnsLookups() => _dnsLookupsTotal++;
  @override
  void incDnsCacheHits() => _dnsCacheHits++;
  @override
  void incDnsCacheMisses() => _dnsCacheMisses++;
  @override
  void incProbes() => _probesTotal++;
  @override
  void incProbesDedupSkipped() => _probesDedupSkipped++;
  @override
  void incCacheEvictions() => _cacheEvictions++;

  @override
  void reset() {
    _requestsTotal = 0;
    _failoversTotal = 0;
    _dnsLookupsTotal = 0;
    _dnsCacheHits = 0;
    _dnsCacheMisses = 0;
    _probesTotal = 0;
    _probesDedupSkipped = 0;
    _cacheEvictions = 0;
  }

  @override
  Map<String, int> snapshot() => <String, int>{
        'requestsTotal': _requestsTotal,
        'failoversTotal': _failoversTotal,
        'dnsLookupsTotal': _dnsLookupsTotal,
        'dnsCacheHits': _dnsCacheHits,
        'dnsCacheMisses': _dnsCacheMisses,
        'probesTotal': _probesTotal,
        'probesDedupSkipped': _probesDedupSkipped,
        'cacheEvictions': _cacheEvictions,
      };
}

/// Zero-allocation no-op metrics used in release builds.
class NoOpFailoverMetrics implements FailoverMetrics {
  /// Creates the const no-op singleton.
  const NoOpFailoverMetrics();

  @override
  int get requestsTotal => 0;
  @override
  int get failoversTotal => 0;
  @override
  int get dnsLookupsTotal => 0;
  @override
  int get dnsCacheHits => 0;
  @override
  int get dnsCacheMisses => 0;
  @override
  int get probesTotal => 0;
  @override
  int get probesDedupSkipped => 0;
  @override
  int get cacheEvictions => 0;

  @override
  void incRequests() {}
  @override
  void incFailovers() {}
  @override
  void incDnsLookups() {}
  @override
  void incDnsCacheHits() {}
  @override
  void incDnsCacheMisses() {}
  @override
  void incProbes() {}
  @override
  void incProbesDedupSkipped() {}
  @override
  void incCacheEvictions() {}

  @override
  void reset() {}

  @override
  Map<String, int> snapshot() => const <String, int>{};
}
