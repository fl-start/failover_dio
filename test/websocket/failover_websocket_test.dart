import 'dart:io';

import 'package:failover_dio/failover_dio.dart';
import 'package:failover_dio/failover_dio_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FailoverWebSocket', () {
    late HttpServer server;
    late int port;
    final List<String> connectLog = <String>[];

    setUp(() async {
      connectLog.clear();
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      port = server.port;
      server.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          connectLog.add(request.connectionInfo?.remoteAddress.address ?? '?');
          final WebSocket ws = await WebSocketTransformer.upgrade(request);
          ws.listen((dynamic msg) {
            if (msg == 'ping') {
              ws.add('pong');
            }
          });
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
      FailoverDio.clearHostCache();
    });

    test('connects to ranked IP over ws://', () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1'],
        },
      );
      final FailoverWebSocket ws = await FailoverWebSocket.connect(
        'ws://fake.host.test:$port/ws',
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );
      addTearDown(ws.close);

      expect(ws.winningIp, '127.0.0.1');
      expect(ws.connectAttempts, hasLength(1));
      expect(ws.connectAttempts.first.outcome, AttemptOutcome.succeeded);

      await ws.send('ping');
      final String reply = await ws.stream.first as String;
      expect(reply, 'pong');
      expect(connectLog, contains('127.0.0.1'));
    });

    test('multi-IP: fails over connect to second loopback IP', () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1', '127.0.0.1'],
        },
      );
      final FailoverWebSocket ws = await FailoverWebSocket.connect(
        'ws://fake.host.test:$port/ws',
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          probeTimeout: const Duration(milliseconds: 300),
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );
      addTearDown(ws.close);

      expect(ws.winningIp, '127.0.0.1');
      expect(ws.connectAttempts.length, greaterThanOrEqualTo(2));
      expect(
        ws.connectAttempts.any((AttemptRecord a) => a.outcome == AttemptOutcome.failed),
        isTrue,
      );
    });

    test('reconnect: retries same IP then next ranked IP (curl_fo policy)',
        () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1', '127.0.0.2'],
        },
      );
      final List<FailoverEvent> events = <FailoverEvent>[];
      final FailoverWebSocket ws = await FailoverWebSocket.connect(
        'ws://fake.host.test:$port/ws',
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          onEvent: events.add,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );
      addTearDown(ws.close);

      final String firstIp = ws.winningIp;
      await ws.socket.close();

      await ws.reconnect();
      expect(ws.winningIp, isNotEmpty);
      expect(
        events.whereType<WebSocketReconnecting>(),
        isNotEmpty,
      );
      expect(
        events.whereType<WebSocketReconnected>(),
        isNotEmpty,
      );

      // curl_fo: first reconnect is same IP.
      expect(ws.winningIp, firstIp);
    });
  });
}
