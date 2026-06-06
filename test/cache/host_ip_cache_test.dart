import 'dart:async';
import 'dart:math';

import 'package:failover_dio/failover_dio.dart';
import 'package:failover_dio/failover_dio_testing.dart';
import 'package:test/test.dart';

void main() {
  group('HostIpCache (with FakeDnsResolver)', () {
    late FakeDnsResolver resolver;
    late HostIpCache cache;
    late FailoverOptions options;

    setUp(() {
      resolver = FakeDnsResolver(
        <String, List<String>>{
          'api.example.com': <String>['10.0.0.1', '10.0.0.2', '10.0.0.3'],
        },
        ttl: const Duration(seconds: 60),
      );
      options = FailoverOptions(
        dnsResolver: resolver,
        useSharedCache: false,
      );
      cache = HostIpCache(resolver: resolver, options: options);
    });

    test('first resolveIfNeeded triggers DNS and caches', () async {
      final entries = await cache.resolveIfNeeded('api.example.com');
      expect(entries, hasLength(3));
      expect(entries.map((e) => e.addressString),
          containsAll(<String>['10.0.0.1', '10.0.0.2', '10.0.0.3']));
      expect(resolver.callCount, 1);
    });

    test('second resolveIfNeeded within TTL is a cache hit', () async {
      await cache.resolveIfNeeded('api.example.com');
      await cache.resolveIfNeeded('api.example.com');
      expect(resolver.callCount, 1);
    });

    test('case-insensitive cache lookup', () async {
      await cache.resolveIfNeeded('API.example.com');
      await cache.resolveIfNeeded('api.example.com.');
      expect(resolver.callCount, 1);
    });

    test('orderedEntries puts probed lowest-latency first', () async {
      await cache.resolveIfNeeded('api.example.com');
      cache.recordLatency('api.example.com',
          (await cache.resolveIfNeeded('api.example.com'))[0].address, 50);
      cache.recordLatency('api.example.com',
          (await cache.resolveIfNeeded('api.example.com'))[1].address, 5);
      cache.recordLatency('api.example.com',
          (await cache.resolveIfNeeded('api.example.com'))[2].address, 200);

      final ordered = cache.orderedEntries('api.example.com');
      expect(ordered.first.latencyMs, 5);
      expect(ordered.last.latencyMs, 200);
    });

    test('mark unavailable pushes to end of ordered', () async {
      await cache.resolveIfNeeded('api.example.com');
      final entries = await cache.resolveIfNeeded('api.example.com');
      cache.markUnavailable('api.example.com', entries[0].address);
      final ordered = cache.orderedEntries('api.example.com');
      expect(ordered.last.addressString, entries[0].addressString);
    });

    test('single-flight: concurrent first calls share one DNS lookup',
        () async {
      final List<Future<void>> futures = <Future<void>>[
        cache.resolveIfNeeded('api.example.com'),
        cache.resolveIfNeeded('api.example.com'),
        cache.resolveIfNeeded('api.example.com'),
      ];
      await Future.wait<void>(futures);
      expect(resolver.callCount, 1);
    });

    test('negative cache: failed lookups short-circuit during TTL', () async {
      final emptyResolver = FakeDnsResolver(const <String, List<String>>{});
      final localCache = HostIpCache(
        resolver: emptyResolver,
        options: FailoverOptions(
          dnsResolver: emptyResolver,
          useSharedCache: false,
          negativeCacheTtl: const Duration(seconds: 5),
        ),
      );
      await expectLater(
        () async => localCache.resolveIfNeeded('missing.example.com'),
        throwsA(isA<Object>()),
      );
      await expectLater(
        () async => localCache.resolveIfNeeded('missing.example.com'),
        throwsA(isA<Object>()),
      );
      // Second call must short-circuit via the negative cache.
      expect(emptyResolver.callCount, 1);
    });

    test('snapshot reflects cache state', () async {
      await cache.resolveIfNeeded('api.example.com');
      final snap = cache.snapshot();
      expect(snap.size, 1);
      expect(snap.hosts['api.example.com']!.ips, hasLength(3));
    });

    test('evict removes the host', () async {
      await cache.resolveIfNeeded('api.example.com');
      cache.evict('api.example.com');
      expect(cache.contains('api.example.com'), isFalse);
    });

    // ── Latency bucketing ────────────────────────────────────────────────

    test('orderedEntries: IPs in different latency buckets are always ordered '
        'by bucket (improvement 2)', () async {
      await cache.resolveIfNeeded('api.example.com');
      final entries = await cache.resolveIfNeeded('api.example.com');
      // 5 ms → bucket 0, 50 ms → bucket 5, 200 ms → bucket 20
      cache.recordLatency('api.example.com', entries[0].address, 5);
      cache.recordLatency('api.example.com', entries[1].address, 200);
      cache.recordLatency('api.example.com', entries[2].address, 50);

      // Run 10 times: bucket order must always hold (5 < 50 < 200 by bucket).
      for (int i = 0; i < 10; i++) {
        final ordered = cache.orderedEntries('api.example.com');
        expect(ordered[0].latencyMs, 5,
            reason: 'bucket-0 IP must always be first');
        expect(ordered[1].latencyMs, 50,
            reason: 'bucket-5 IP must always be second');
        expect(ordered[2].latencyMs, 200,
            reason: 'bucket-20 IP must always be last');
      }
    });

    test('orderedEntries: IPs in same latency bucket are randomly distributed '
        '(improvement 2)', () async {
      // Use a seeded random so the test outcome is reproducible but we can
      // still see that different orderings occur over multiple calls.
      final seededOptions = FailoverOptions(
        dnsResolver: resolver,
        useSharedCache: false,
        latencyBucketMs: 10,
        random: Random(42),
      );
      final seededCache = HostIpCache(
        resolver: resolver,
        options: seededOptions,
      );
      await seededCache.resolveIfNeeded('api.example.com');
      final entries = await seededCache.resolveIfNeeded('api.example.com');
      // 12 ms and 14 ms both in bucket 1 (12~14 / 10 == 1)
      seededCache.recordLatency('api.example.com', entries[0].address, 12);
      seededCache.recordLatency('api.example.com', entries[1].address, 14);
      seededCache.recordLatency('api.example.com', entries[2].address, 200);

      // Collect orderings over several calls.
      final firsts = <String>{};
      for (int i = 0; i < 20; i++) {
        final ordered = seededCache.orderedEntries('api.example.com');
        // Last is always the 200 ms IP (bucket 20).
        expect(ordered.last.latencyMs, 200);
        firsts.add(ordered.first.addressString);
      }
      // Over 20 calls the two bucket-1 IPs should both appear first at
      // least once (with overwhelming probability for any sane random seed).
      expect(firsts.length, greaterThan(1),
          reason: 'same-bucket IPs should be randomly shuffled');
    });

    // ── TTL-smart re-probe ───────────────────────────────────────────────

    test('TTL refresh preserves lastProbedAt when top IP is still in DNS set '
        '(improvement 3)', () async {
      // Resolver returns all three IPs on both calls.
      final stableResolver = FakeDnsResolver(
        const <String, List<String>>{
          'api.example.com': <String>['10.0.0.1', '10.0.0.2', '10.0.0.3'],
        },
        ttl: const Duration(milliseconds: 1),
      );
      final localCache = HostIpCache(
        resolver: stableResolver,
        options: FailoverOptions(
          dnsResolver: stableResolver,
          useSharedCache: false,
          staleWhileRevalidate: false,
        ),
      );
      final entries = await localCache.resolveIfNeeded('api.example.com');
      // 10.0.0.2 is the top IP (5 ms).
      localCache.recordLatency('api.example.com', entries[0].address, 50);
      localCache.recordLatency('api.example.com', entries[1].address, 5);
      localCache.recordLatency('api.example.com', entries[2].address, 200);

      // Force TTL expiry then re-resolve.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await localCache.resolveIfNeeded('api.example.com');

      // Top IP (10.0.0.2) is still present → lastProbedAt must be preserved
      // so ProbeScheduler doesn't immediately re-probe.
      final row = localCache.rowOf('api.example.com')!;
      final topEntry = row.entries.firstWhere(
        (e) => e.addressString == '10.0.0.2',
      );
      expect(topEntry.latencyMs, 5,
          reason: 'latencyMs must be preserved for existing IP');
      expect(topEntry.lastProbedAt, isNotNull,
          reason: 'lastProbedAt must be preserved when top IP is still present');
    });

    test('TTL refresh clears lastProbedAt when top IP leaves the DNS set '
        '(improvement 3)', () async {
      // First resolve returns 3 IPs; second resolve drops 10.0.0.2 (top).
      int callCount = 0;
      final changingResolver = FakeDnsResolver.withFactory(
        (String host) {
          callCount++;
          if (callCount == 1) {
            return <String>['10.0.0.1', '10.0.0.2', '10.0.0.3'];
          }
          // Top IP 10.0.0.2 is gone.
          return <String>['10.0.0.1', '10.0.0.3'];
        },
        ttl: const Duration(milliseconds: 1),
      );
      // Disable stale-while-revalidate so the second resolveIfNeeded
      // performs a synchronous (not background) DNS refresh, ensuring the
      // entries are updated before we read them.
      final localCache = HostIpCache(
        resolver: changingResolver,
        options: FailoverOptions(
          dnsResolver: changingResolver,
          useSharedCache: false,
          staleWhileRevalidate: false,
        ),
      );
      final entries = await localCache.resolveIfNeeded('api.example.com');
      localCache.recordLatency('api.example.com', entries[0].address, 50);
      localCache.recordLatency('api.example.com', entries[1].address, 5);
      localCache.recordLatency('api.example.com', entries[2].address, 200);

      // Force TTL expiry then re-resolve synchronously.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await localCache.resolveIfNeeded('api.example.com');

      // Top IP (10.0.0.2) is gone → remaining IPs should have lastProbedAt
      // cleared to force a re-probe.
      final row = localCache.rowOf('api.example.com')!;
      for (final e in row.entries) {
        expect(e.lastProbedAt, isNull,
            reason:
                'lastProbedAt must be cleared when top IP leaves DNS set '
                '(${e.addressString})');
      }
    });

    // ── Cooldown jitter ──────────────────────────────────────────────────

    test('markUnavailable applies ±10% jitter to cooldown (improvement 5)',
        () async {
      // Use a seeded random for deterministic jitter in the test.
      const base = Duration(seconds: 60);
      final jitteredOptions = FailoverOptions(
        dnsResolver: resolver,
        useSharedCache: false,
        unavailableCooldownInitial: base,
        unavailableCooldownMax: const Duration(minutes: 15),
        random: Random(0),
      );
      final localCache = HostIpCache(
        resolver: jitteredOptions.dnsResolver,
        options: jitteredOptions,
      );
      await localCache.resolveIfNeeded('api.example.com');
      final entries = await localCache.resolveIfNeeded('api.example.com');

      // Mark all three IPs unavailable and collect their cooldown durations.
      final now = DateTime.now();
      final cooldowns = <Duration>[];
      for (final e in entries) {
        localCache.markUnavailable('api.example.com', e.address);
        final row = localCache.rowOf('api.example.com')!;
        final entry = row.entries
            .firstWhere((x) => x.addressString == e.addressString);
        cooldowns.add(entry.unavailableUntil!.difference(now));
      }

      // Each cooldown must be within ≈[54s, 66s] = base ± 10%.
      // We add a small slack (±5s) to absorb wall-clock measurement drift.
      final int lowerBound = (base.inMilliseconds * 0.85).round() - 5000;
      final int upperBound = (base.inMilliseconds * 1.15).round() + 5000;
      for (final cd in cooldowns) {
        expect(cd.inMilliseconds, greaterThanOrEqualTo(lowerBound),
            reason: 'cooldown should be at least 85% of base');
        expect(cd.inMilliseconds, lessThanOrEqualTo(upperBound),
            reason: 'cooldown should be at most 115% of base');
      }
    });

    test('markUnavailable transient: uses short cooldown without incrementing '
        'failure counter (improvement 4 + 5)', () async {
      await cache.resolveIfNeeded('api.example.com');
      final entries = await cache.resolveIfNeeded('api.example.com');
      final ip = entries[0].address;

      // Mark transient — failure counter should stay 0.
      cache.markUnavailable('api.example.com', ip, transient: true);
      final row = cache.rowOf('api.example.com')!;
      final entry =
          row.entries.firstWhere((e) => e.address.address == ip.address);
      expect(entry.consecutiveFailures, 0,
          reason: 'transient mark must not increment consecutiveFailures');
      expect(entry.unavailableUntil, isNotNull);
      // Transient cooldown is half of unavailableCooldownInitial (60s → ~30s).
      final cooldown = entry.unavailableUntil!.difference(DateTime.now());
      expect(cooldown.inSeconds, lessThan(35),
          reason: 'transient cooldown should be shorter than initial 60s');
    });
  });
}
