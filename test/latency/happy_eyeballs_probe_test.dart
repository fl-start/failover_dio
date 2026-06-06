import 'dart:io';

import 'package:failover_dio/failover_dio.dart';
import 'package:failover_dio/failover_dio_testing.dart';
import 'package:failover_dio/src/latency/happy_eyeballs_probe.dart';
import 'package:failover_dio/src/latency/probe_scheduler.dart';
import 'package:test/test.dart';

void main() {
  group('HappyEyeballsProbe', () {
    List<IpEntry> entries() => <IpEntry>[
          IpEntry(
            address: InternetAddress('10.0.0.1'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
            dnsOrder: 0,
          ),
          IpEntry(
            address: InternetAddress('10.0.0.2'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
            dnsOrder: 1,
          ),
          IpEntry(
            address: InternetAddress('10.0.0.3'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
            dnsOrder: 2,
          ),
        ];

    test('race returns after first arrival, not after slowest peer', () async {
      final FakeLatencyProbe probe = FakeLatencyProbe(
        <String, int?>{
          '10.0.0.1': 300,
          '10.0.0.2': 5,
          '10.0.0.3': 200,
        },
        delays: <String, Duration>{
          '10.0.0.1': const Duration(milliseconds: 200),
          '10.0.0.2': const Duration(milliseconds: 10),
          '10.0.0.3': const Duration(milliseconds: 150),
        },
      );
      final HappyEyeballsProbe racer = HappyEyeballsProbe(probe: probe);
      final List<HappyEyeballsProbeResult> seen =
          <HappyEyeballsProbeResult>[];
      final Stopwatch sw = Stopwatch()..start();

      final HappyEyeballsProbeResult? first = await racer.race(
        entries: entries(),
        port: 80,
        timeout: const Duration(seconds: 5),
        onResult: seen.add,
      );
      sw.stop();

      expect(first, isNotNull);
      expect(first!.entry.addressString, '10.0.0.2');
      expect(first.completionOrder, 0);
      // Must unblock well before the slowest peer (200ms + margin).
      expect(sw.elapsedMilliseconds, lessThan(120));
      expect(seen, hasLength(1));

      // Background peers still complete.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(seen, hasLength(3));
      expect(seen.map((HappyEyeballsProbeResult r) => r.completionOrder),
          orderedEquals(<int>[0, 1, 2]));
    });

    test('raceAll waits for every peer', () async {
      final FakeLatencyProbe probe = FakeLatencyProbe(
        <String, int?>{
          '10.0.0.1': 10,
          '10.0.0.2': 20,
          '10.0.0.3': 30,
        },
        delays: <String, Duration>{
          '10.0.0.1': const Duration(milliseconds: 30),
          '10.0.0.2': const Duration(milliseconds: 20),
          '10.0.0.3': const Duration(milliseconds: 10),
        },
      );
      final HappyEyeballsProbe racer = HappyEyeballsProbe(probe: probe);
      final List<HappyEyeballsProbeResult> seen =
          <HappyEyeballsProbeResult>[];

      final List<HappyEyeballsProbeResult> all = await racer.raceAll(
        entries: entries(),
        port: 80,
        timeout: const Duration(seconds: 5),
        onResult: seen.add,
      );

      expect(all, hasLength(3));
      expect(all.first.entry.addressString, '10.0.0.3');
      expect(probe.callCount, 3);
    });
  });

  group('ProbeScheduler Happy Eyeballs', () {
    late FakeDnsResolver resolver;
    late HostIpCache cache;
    late ProbeScheduler scheduler;
    late List<LatencyProbed> events;

    setUp(() async {
      resolver = FakeDnsResolver(
        <String, List<String>>{
          'api.example.com': <String>['10.0.0.1', '10.0.0.2', '10.0.0.3'],
        },
      );
      events = <LatencyProbed>[];
      cache = HostIpCache(
        resolver: resolver,
        options: FailoverOptions(
          dnsResolver: resolver,
          useSharedCache: false,
          probeFreshness: const Duration(seconds: 30),
        ),
      );
      await cache.resolveIfNeeded('api.example.com');

      scheduler = ProbeScheduler(
        probe: FakeLatencyProbe(
          <String, int?>{
            '10.0.0.1': 300,
            '10.0.0.2': 5,
            '10.0.0.3': 200,
          },
          delays: <String, Duration>{
            '10.0.0.1': const Duration(milliseconds: 200),
            '10.0.0.2': const Duration(milliseconds: 10),
            '10.0.0.3': const Duration(milliseconds: 150),
          },
        ),
        cache: cache,
        options: FailoverOptions(
          dnsResolver: resolver,
          useSharedCache: false,
          probeFreshness: const Duration(seconds: 30),
        ),
        onEvent: (FailoverEvent e) {
          if (e is LatencyProbed) events.add(e);
        },
      );
    });

    test('raceHappyEyeballs unblocks on first TCP connect', () async {
      final Stopwatch sw = Stopwatch()..start();
      await scheduler.raceHappyEyeballs('api.example.com', port: 80);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(120));
      final List<IpEntry> ordered = cache.orderedEntries('api.example.com');
      expect(ordered.first.latencyMs, 5);
      expect(events.first.completionOrder, 0);
      expect(events.first.ip, '10.0.0.2');

      await scheduler.drain();
      expect(events, hasLength(3));
    });

    test('hasFreshLatencyRanking skips cold-start wait on repeat calls',
        () async {
      await scheduler.raceHappyEyeballs('api.example.com', port: 80);
      await scheduler.drain();

      expect(scheduler.hasFreshLatencyRanking(
          cache.orderedEntries('api.example.com')), isTrue);
    });
  });
}
