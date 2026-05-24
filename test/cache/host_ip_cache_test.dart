import 'dart:async';

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
  });
}
