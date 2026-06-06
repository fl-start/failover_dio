import 'dart:async';
import 'dart:io';

import '../config/failover_options.dart';
import '../dns/dns_resolver.dart';
import '../observability/cache_inspector.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../util/address_validator.dart';
import '../util/build_mode.dart';
import '../util/clock.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import '../util/monotonic_time.dart';
import 'ip_entry.dart';
import 'lru_eviction.dart';

/// Per-host cache row including DNS-fresh entries and an LRU access mark.
class HostCacheRow {
  /// Creates a row.
  HostCacheRow({required this.entries, required this.lastResolvedAt});

  /// Cached IPs for the host.
  List<IpEntry> entries;

  /// Wall-clock time of the last successful DNS resolution.
  DateTime lastResolvedAt;

  /// Wall-clock time of the last cache read.
  DateTime lastAccessedAt = DateTime.now();

  /// Used by single-flight DNS coalescing.
  Future<void>? inflightResolve;

  /// Negative cache entry: when this is in the future, [entries] is empty
  /// and lookups for this host should fail fast.
  DateTime? negativeCacheUntil;

  /// Last error from a failed lookup (returned during negative cache).
  Object? lastError;
}

/// Process-wide host → IP cache.
///
/// The shared singleton is exposed via [HostIpCache.shared]; users that
/// need isolation per-Dio (e.g. tests) can construct a [HostIpCache]
/// directly. The cache owns DNS resolution, TTL-based expiry, optional
/// stale-while-revalidate, LRU eviction, and an event/log sink that the
/// adapter subscribes to.
class HostIpCache {
  /// Creates a cache with the given dependencies.
  HostIpCache({
    required this.resolver,
    required this.options,
    Clock clock = const SystemClock(),
    FailoverLogger logger = const NoOpFailoverLogger(),
    AddressValidator? addressValidator,
    void Function(FailoverEvent)? onEvent,
  })  : _clock = clock,
        _logger = logger,
        _addressValidator = addressValidator ??
            AddressValidator(
              allowPrivate: options.allowPrivateAddresses,
              localHosts: options.dnsLocalHosts,
            ),
        _onEvent = onEvent,
        _lru = LruTracker<String>(options.maxCachedHosts);

  /// Shared, lazy-initialised, process-wide cache.
  static HostIpCache? _shared;

  /// Fan-out list of event subscribers attached to the shared cache.
  /// Each `FailoverHttpClientAdapter` registers its `onEvent` callback so
  /// every Dio instance sees cache-level events (HostResolved,
  /// CacheRefreshed, IpMarkedUnavailable, CacheEvicted), even when they
  /// share the process-wide singleton.
  static final List<void Function(FailoverEvent)> _sharedListeners =
      <void Function(FailoverEvent)>[];

  /// Returns the shared singleton, constructing it on first use with
  /// [defaultOptions].
  static HostIpCache sharedWithDefaults(FailoverOptions defaultOptions) {
    return _shared ??= HostIpCache(
      resolver: defaultOptions.dnsResolver,
      options: defaultOptions,
      addressValidator: AddressValidator(
        allowPrivate: defaultOptions.allowPrivateAddresses,
        localHosts: defaultOptions.dnsLocalHosts,
      ),
      onEvent: _fanoutSharedEvent,
    );
  }

  /// Registers a listener on the shared cache's fan-out. Returns a
  /// removal closure the caller should invoke on Dio dispose.
  static void Function() addSharedListener(
      void Function(FailoverEvent) listener) {
    _sharedListeners.add(listener);
    return () => _sharedListeners.remove(listener);
  }

  static void _fanoutSharedEvent(FailoverEvent e) {
    for (final void Function(FailoverEvent) l
        in List<void Function(FailoverEvent)>.from(_sharedListeners)) {
      try {
        l(e);
      } catch (_) {
        // Swallow listener errors; they must not poison fan-out.
      }
    }
  }

  /// Returns the shared instance if already constructed, else `null`.
  static HostIpCache? get shared => _shared;

  /// Tears down the shared singleton (cancels probes, releases timers).
  static Future<void> disposeShared() async {
    final HostIpCache? s = _shared;
    _shared = null;
    if (s != null) {
      await s.dispose();
    }
  }

  /// Wipes all entries from the shared singleton (or one [host] if given).
  static void clearShared([String? host]) {
    final HostIpCache? s = _shared;
    if (s == null) return;
    if (host == null) {
      s.clear();
    } else {
      s.evict(host);
    }
  }

  /// The DNS resolver used for misses and refreshes.
  DnsResolver resolver;

  /// Cache + adapter configuration.
  FailoverOptions options;

  final Clock _clock;
  final FailoverLogger _logger;
  final AddressValidator _addressValidator;
  final void Function(FailoverEvent)? _onEvent;
  final LruTracker<String> _lru;

  final Map<String, HostCacheRow> _rows = <String, HostCacheRow>{};

  /// Returns the current row for [host], if any.
  HostCacheRow? rowOf(String host) => _rows[HostnameNormalizer.normalize(host)];

  /// Resolves and caches a host on-demand.
  ///
  /// - Returns cached entries if at least one is fresh.
  /// - With [FailoverOptions.staleWhileRevalidate], returns stale entries
  ///   immediately while refreshing in the background, bounded by
  ///   [FailoverOptions.maxStaleAge].
  /// - Single-flight: concurrent calls for the same cold host share one
  ///   resolution future.
  /// - Negative cache short-circuit: if a recent failure is still in the
  ///   negative TTL window, throws the cached error.
  Future<List<IpEntry>> resolveIfNeeded(String host) async {
    final String h = HostnameNormalizer.normalize(host);
    final DateTime now = _clock.now();
    final int nowMicros = MonotonicTime.nowMicros();

    final HostCacheRow? row = _rows[h];

    // Negative cache short-circuit.
    if (row != null &&
        row.negativeCacheUntil != null &&
        row.negativeCacheUntil!.isAfter(now)) {
      throw row.lastError ?? const SocketException('DNS negative cache hit');
    }

    if (row != null && row.entries.isNotEmpty) {
      row.lastAccessedAt = now;
      _lru.touch(h);

      final bool anyFresh = row.entries.any((IpEntry e) => !e.isExpired(nowMicros));
      if (anyFresh) {
        FailoverMetrics.instance.incDnsCacheHits();
        return List<IpEntry>.unmodifiable(row.entries);
      }

      // Stale; check stale-while-revalidate window.
      if (options.staleWhileRevalidate) {
        final int oldestExpiry = row.entries
            .map((IpEntry e) => e.expiresAtMicros)
            .reduce((int a, int b) => a < b ? a : b);
        final int staleAgeMicros = nowMicros - oldestExpiry;
        if (staleAgeMicros <= options.maxStaleAge.inMicroseconds) {
          FailoverMetrics.instance.incDnsCacheHits();
          unawaited(_refresh(h, row, isBackground: true));
          return List<IpEntry>.unmodifiable(row.entries);
        }
      }
    }

    FailoverMetrics.instance.incDnsCacheMisses();
    await _refresh(h, row, isBackground: false);
    final HostCacheRow? refreshed = _rows[h];
    if (refreshed == null || refreshed.entries.isEmpty) {
      throw refreshed?.lastError ??
          SocketException('DNS resolution for $h returned no usable addresses');
    }
    return List<IpEntry>.unmodifiable(refreshed.entries);
  }

  /// Returns the cached entries for [host] ordered by:
  ///
  /// 1. Available entries first (unavailable last).
  /// 2. Within available, ascending by latency bucket
  ///    (`latencyMs ~/ latencyBucketMs`). IPs with no latency data sort
  ///    after all probed entries.
  /// 3. Within the same bucket, randomly reordered to distribute load
  ///    across statistically equivalent gateways (matches curl_fo's
  ///    random tie-break behaviour).
  List<IpEntry> orderedEntries(String host) {
    final String h = HostnameNormalizer.normalize(host);
    final HostCacheRow? row = _rows[h];
    if (row == null) return const <IpEntry>[];
    final DateTime now = _clock.now();
    final List<IpEntry> available = <IpEntry>[];
    final List<IpEntry> unavailable = <IpEntry>[];
    for (final IpEntry e in row.entries) {
      if (e.isUnavailable(now)) {
        unavailable.add(e);
      } else {
        available.add(e);
      }
    }
    // Pre-compute a random tie-break key per entry so the comparator is
    // internally consistent (a stable sort key), while still producing a
    // different order on each call for within-bucket load distribution.
    final int bucket = options.latencyBucketMsFor(h).clamp(1, 100000);
    final Map<IpEntry, int> tieBreak = <IpEntry, int>{
      for (final IpEntry e in available) e: options.random.nextInt(0x7fffffff),
    };
    available.sort((IpEntry a, IpEntry b) {
      final int? la = a.latencyMs;
      final int? lb = b.latencyMs;
      if (la == null && lb == null) {
        return tieBreak[a]!.compareTo(tieBreak[b]!);
      }
      if (la == null) return 1;
      if (lb == null) return -1;
      final int ba = la ~/ bucket;
      final int bb = lb ~/ bucket;
      if (ba != bb) return ba.compareTo(bb);
      // Same latency bucket: random load distribution.
      return tieBreak[a]!.compareTo(tieBreak[b]!);
    });
    return <IpEntry>[...available, ...unavailable];
  }

  /// Marks [ip] for [host] as unavailable with exponential cooldown.
  ///
  /// Cooldown = `unavailableCooldownInitial * factor ^ consecutiveFailures`,
  /// clamped to [FailoverOptions.unavailableCooldownMax], plus ±10% jitter
  /// to prevent thundering herd when multiple clients share a cache.
  ///
  /// When [transient] is `true` (status-code fail-over, e.g. 502/503/504),
  /// a shorter fixed cooldown (`unavailableCooldownInitial / 2`) is applied
  /// without incrementing the consecutive-failure counter. This avoids
  /// aggressively penalising a gateway that is merely transiently overloaded.
  void markUnavailable(String host, InternetAddress ip,
      {bool transient = false}) {
    final HostCacheRow? row = _rows[HostnameNormalizer.normalize(host)];
    if (row == null) return;
    for (final IpEntry e in row.entries) {
      if (e.address == ip || e.address.address == ip.address) {
        final Duration baseCooldown;
        if (transient) {
          // Short fixed cooldown; consecutive-failure counter unchanged.
          baseCooldown = Duration(
            microseconds:
                options.unavailableCooldownInitial.inMicroseconds ~/ 2,
          );
        } else {
          e.consecutiveFailures++;
          final double seconds =
              options.unavailableCooldownInitial.inSeconds *
                  _pow(
                    options.unavailableCooldownFactor,
                    e.consecutiveFailures - 1,
                  );
          baseCooldown = Duration(
            milliseconds: (seconds * 1000).clamp(
              options.unavailableCooldownInitial.inMilliseconds.toDouble(),
              options.unavailableCooldownMax.inMilliseconds.toDouble(),
            ).toInt(),
          );
        }
        // ±10% jitter to spread cooldown expiry across clients.
        final double jitter = 0.9 + options.random.nextDouble() * 0.2;
        final Duration jittered = Duration(
          microseconds: (baseCooldown.inMicroseconds * jitter).round(),
        );
        final DateTime until = _clock.now().add(jittered);
        e.unavailableUntil = until;
        _emit(IpMarkedUnavailable(
          host: HostnameNormalizer.normalize(host),
          ip: e.addressString,
          until: until,
        ));
        _logger.log(
          transient ? FailoverLogLevel.debug : FailoverLogLevel.warn,
          'ip_marked_unavailable',
          fields: <String, Object?>{
            'host': host,
            'ip': e.addressString,
            'until': until.toIso8601String(),
            'failures': e.consecutiveFailures,
            'transient': transient,
          },
        );
        return;
      }
    }
  }

  /// Resets failure counter and clears unavailability after a successful
  /// request to [ip] for [host].
  void markAvailable(String host, InternetAddress ip) {
    final HostCacheRow? row = _rows[HostnameNormalizer.normalize(host)];
    if (row == null) return;
    for (final IpEntry e in row.entries) {
      if (e.address == ip || e.address.address == ip.address) {
        e.consecutiveFailures = 0;
        e.unavailableUntil = null;
        return;
      }
    }
  }

  /// Records a latency probe outcome for [ip] under [host].
  void recordLatency(String host, InternetAddress ip, int? latencyMs) {
    final HostCacheRow? row = _rows[HostnameNormalizer.normalize(host)];
    if (row == null) return;
    for (final IpEntry e in row.entries) {
      if (e.address == ip || e.address.address == ip.address) {
        e.latencyMs = latencyMs;
        e.lastProbedAt = _clock.now();
        return;
      }
    }
  }

  /// Removes the cache row for [host].
  void evict(String host) {
    final String h = HostnameNormalizer.normalize(host);
    final bool removed = _rows.remove(h) != null;
    _lru.forget(h);
    if (removed) {
      FailoverMetrics.instance.incCacheEvictions();
      _emit(CacheEvicted(host: h, reason: 'explicit'));
    }
  }

  /// Wipes the entire cache.
  void clear() {
    final List<String> hosts = _rows.keys.toList(growable: false);
    _rows.clear();
    for (final String h in hosts) {
      _lru.forget(h);
      _emit(CacheEvicted(host: h, reason: 'explicit'));
    }
  }

  /// Returns a deep-copied snapshot for inspection.
  CacheSnapshot snapshot() {
    final Map<String, HostSnapshot> hosts = <String, HostSnapshot>{};
    final int nowMicros = MonotonicTime.nowMicros();
    for (final MapEntry<String, HostCacheRow> e in _rows.entries) {
      final HostCacheRow row = e.value;
      final List<String> ips = <String>[];
      final Map<String, int?> lat = <String, int?>{};
      final Map<String, DateTime?> un = <String, DateTime?>{};
      int? minRemaining;
      for (final IpEntry ip in row.entries) {
        ips.add(ip.addressString);
        lat[ip.addressString] = ip.latencyMs;
        un[ip.addressString] = ip.unavailableUntil;
        final int remaining = ip.expiresAtMicros - nowMicros;
        if (minRemaining == null || remaining < minRemaining) {
          minRemaining = remaining;
        }
      }
      hosts[e.key] = HostSnapshot(
        host: e.key,
        ips: ips,
        latencyMs: lat,
        unavailableUntil: un,
        ttlRemainingMs: (minRemaining ?? 0) ~/ 1000,
        lastResolvedAt: row.lastResolvedAt,
        lastAccessedAt: row.lastAccessedAt,
      );
    }
    return CacheSnapshot(hosts: hosts);
  }

  /// Whether [host] has at least one cached entry.
  bool contains(String host) {
    final HostCacheRow? row = _rows[HostnameNormalizer.normalize(host)];
    return row != null && row.entries.isNotEmpty;
  }

  /// Disposes any in-flight probes/timers owned by the cache.
  Future<void> dispose() async {
    _rows.clear();
  }

  Future<void> _refresh(String h, HostCacheRow? row, {required bool isBackground}) {
    // Single-flight: if an in-flight resolution is in progress, await it.
    if (row != null && row.inflightResolve != null) {
      return row.inflightResolve!;
    }
    final Completer<void> completer = Completer<void>();
    final HostCacheRow target = row ??
        HostCacheRow(entries: <IpEntry>[], lastResolvedAt: _clock.now());
    _rows[h] = target;
    target.inflightResolve = completer.future;

    Future<void>(() async {
      final Stopwatch sw = Stopwatch()..start();
      FailoverMetrics.instance.incDnsLookups();
      try {
        final DnsAnswer ans = await resolver.resolve(h);
        sw.stop();
        final List<InternetAddress> filtered = ans.addresses
            .where((InternetAddress a) => _addressValidator.isAllowed(a, h))
            .toList(growable: false);
        if (filtered.isEmpty) {
          throw const SocketException(
              'DNS answer contained no addresses passing the address validator');
        }
        final int nowMicros = MonotonicTime.nowMicros();
        final int ttlMicros = ans.ttl.inMicroseconds;
        final List<String> before =
            target.entries.map((IpEntry e) => e.addressString).toList();

        // TTL-smart re-probe (matches curl_fo behaviour):
        // Identify the current best IP (lowest latencyMs, non-null) before
        // merging. If it is still present in the refreshed DNS answer we
        // keep all existing latency rankings and do not force a re-probe.
        // If the top IP has left the DNS set (topology change), we clear
        // lastProbedAt for every entry so ProbeScheduler runs a full
        // re-probe on the next request.
        final String? topIpBefore = _topIpAddress(target.entries);
        final Set<String> newAddressSet = <String>{
          for (final InternetAddress a in filtered) a.address,
        };
        final bool topIpStillPresent =
            topIpBefore == null || newAddressSet.contains(topIpBefore);

        final List<IpEntry> merged = _mergeEntries(
          old: target.entries,
          newAddresses: filtered,
          ttlSeconds: ans.ttl.inSeconds,
          newExpiryMicros: nowMicros + ttlMicros,
        );

        if (!topIpStillPresent) {
          // Network topology changed: the previously best gateway is gone.
          // Reset probe freshness so all IPs get re-ranked on next request.
          for (final IpEntry e in merged) {
            e.lastProbedAt = null;
          }
        }

        target.entries = merged;
        target.lastResolvedAt = _clock.now();
        target.lastAccessedAt = target.lastResolvedAt;
        target.negativeCacheUntil = null;
        target.lastError = null;
        _lru.touch(h);
        _maybeEvictLru();
        _emit(HostResolved(
          host: h,
          ips: filtered
              .map((InternetAddress a) => a.address)
              .toList(growable: false),
          ttl: ans.ttl,
          durationMs: sw.elapsedMilliseconds,
        ));
        _emit(CacheRefreshed(
          host: h,
          ipsBefore: before,
          ipsAfter:
              merged.map((IpEntry e) => e.addressString).toList(growable: false),
        ));
        _logger.log(FailoverLogLevel.debug, 'resolve_host',
            fields: <String, Object?>{
              'host': h,
              'ips': filtered.map((InternetAddress a) => a.address).toList(),
              'ttl_s': ans.ttl.inSeconds,
              'ms': sw.elapsedMilliseconds,
            });
        completer.complete();
      } catch (e) {
        sw.stop();
        target.negativeCacheUntil = _clock.now().add(options.negativeCacheTtl);
        target.lastError = e;
        if (target.entries.isEmpty) {
          // We failed and have nothing; keep the row so the negative window
          // applies, but mark for LRU eviction.
          _lru.touch(h);
        }
        _logger.log(FailoverLogLevel.warn, 'dns_lookup_failed',
            fields: <String, Object?>{
              'host': h,
              'error': e.toString(),
              'ms': sw.elapsedMilliseconds,
              'background': isBackground,
            });
        if (isBackground) {
          // Don't propagate background failures; cache stays as-is.
          completer.complete();
        } else {
          completer.completeError(e);
        }
      } finally {
        target.inflightResolve = null;
        if (kDebugMode) {
          // ignore: dead_code
          assert(target.inflightResolve == null);
        }
      }
    });

    return completer.future;
  }

  /// Merges new DNS results with existing entries so latency and
  /// unavailability for still-present IPs are preserved.
  List<IpEntry> _mergeEntries({
    required List<IpEntry> old,
    required List<InternetAddress> newAddresses,
    required int ttlSeconds,
    required int newExpiryMicros,
  }) {
    final Map<String, IpEntry> oldByIp = <String, IpEntry>{
      for (final IpEntry e in old) e.address.address: e,
    };
    final List<IpEntry> out = <IpEntry>[];
    for (int i = 0; i < newAddresses.length; i++) {
      final InternetAddress a = newAddresses[i];
      final IpEntry? existing = oldByIp[a.address];
      if (existing != null) {
        existing.expiresAtMicros = newExpiryMicros;
        out.add(IpEntry(
          address: existing.address,
          ttlSeconds: existing.ttlSeconds,
          expiresAtMicros: existing.expiresAtMicros,
          dnsOrder: i,
          latencyMs: existing.latencyMs,
          unavailableUntil: existing.unavailableUntil,
          consecutiveFailures: existing.consecutiveFailures,
          lastProbedAt: existing.lastProbedAt,
        ));
      } else {
        out.add(IpEntry(
          address: a,
          ttlSeconds: ttlSeconds,
          expiresAtMicros: newExpiryMicros,
          dnsOrder: i,
        ));
      }
    }
    return out;
  }

  void _maybeEvictLru() {
    while (_lru.isOverCapacity()) {
      final String? victim = _lru.evictionCandidate();
      if (victim == null) break;
      _rows.remove(victim);
      _lru.forget(victim);
      FailoverMetrics.instance.incCacheEvictions();
      _emit(CacheEvicted(host: victim, reason: 'lru'));
    }
  }

  void _emit(FailoverEvent e) {
    try {
      _onEvent?.call(e);
    } catch (_) {
      // Never let an event subscriber crash the cache.
    }
  }

  /// Returns the address string of the entry with the lowest non-null
  /// latency in [entries], or `null` if none have been probed yet.
  String? _topIpAddress(List<IpEntry> entries) {
    IpEntry? top;
    for (final IpEntry e in entries) {
      if (e.latencyMs == null) continue;
      if (top == null || e.latencyMs! < top.latencyMs!) {
        top = e;
      }
    }
    return top?.addressString;
  }

  /// Computes [base] to the power [exp] where [exp] is a non-negative
  /// integer. Avoids `dart:math` to keep this file dependency-light.
  double _pow(double base, int exp) {
    if (exp <= 0) return 1.0;
    double result = 1.0;
    for (int i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }
}
