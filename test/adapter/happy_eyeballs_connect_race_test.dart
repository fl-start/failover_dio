import 'dart:io';

import 'package:failover_dio/src/adapter/happy_eyeballs_connect_race.dart';
import 'package:failover_dio/src/cache/ip_entry.dart';
import 'package:test/test.dart';

void main() {
  group('HappyEyeballsConnectRace', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((HttpRequest req) async {
        req.response.statusCode = 200;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    List<IpEntry> entries() => <IpEntry>[
          IpEntry(
            address: InternetAddress('192.0.2.1'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
            dnsOrder: 0,
          ),
          IpEntry(
            address: InternetAddress('127.0.0.1'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
            dnsOrder: 1,
          ),
        ];

    test('first SYN+ACK wins and unblocks before slow peer', () async {
      const HappyEyeballsConnectRace race = HappyEyeballsConnectRace();
      final List<(String, int?, int)> completions = <(String, int?, int)>[];
      final Stopwatch sw = Stopwatch()..start();

      final ConnectRaceWinner? winner = await race.race(
        entries: entries(),
        port: port,
        timeout: const Duration(seconds: 5),
        onConnectComplete: (IpEntry entry, int? latencyMs, int order) {
          completions.add((entry.addressString, latencyMs, order));
        },
      );
      sw.stop();

      expect(winner, isNotNull);
      expect(winner!.entry.addressString, '127.0.0.1');
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(completions.first.$1, '127.0.0.1');
    });

    test('returns null when every peer in the batch fails', () async {
      const HappyEyeballsConnectRace race = HappyEyeballsConnectRace();
      final ConnectRaceWinner? winner = await race.race(
        entries: <IpEntry>[
          IpEntry(
            address: InternetAddress('192.0.2.1'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
          ),
          IpEntry(
            address: InternetAddress('192.0.2.2'),
            ttlSeconds: 60,
            expiresAtMicros: 0,
          ),
        ],
        port: port,
        timeout: const Duration(milliseconds: 150),
        onConnectComplete: (_, __, ___) {},
      );
      expect(winner, isNull);
    });
  });
}
