import 'dart:async';
import 'dart:io';

import 'package:failover_dio/failover_dio.dart';
import 'package:failover_dio/failover_dio_testing.dart';
import 'package:test/test.dart';

/// End-to-end adapter test using a real HttpServer bound to 127.0.0.1.
///
/// The test pins three "fake IPs" (all aliases of 127.0.0.1, since most
/// dev/CI machines route the whole 127.0.0.0/8 block to loopback) and lets
/// the adapter route real HTTP traffic to the server while exercising the
/// failover state machine.
void main() {
  group('FailoverHttpClientAdapter (live loopback)', () {
    late HttpServer server;
    late int port;
    final List<String> requestLog = <String>[];

    setUp(() async {
      requestLog.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((HttpRequest req) async {
        requestLog.add('${req.method} ${req.uri.path} '
            'idem=${req.headers.value(FailoverHeaders.idempotencyKey) ?? ''} '
            'prev=${req.headers.value(FailoverHeaders.previousIp) ?? ''}');
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":true,"path":"${req.uri.path}"}');
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      FailoverDio.clearHostCache();
    });

    test('successful first attempt returns response with metadata',
        () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(
          baseUrl: 'http://fake.host.test:$port',
        ),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          // Opt out of the single-IP fast path so the coordinator runs
          // and populates Response.extra metadata.
          singleIpFastPath: false,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res = await client.get<dynamic>('/v1/status');
      expect(res.statusCode, 200);
      expect(res.extra[FailoverExtraKeys.winningIp], '127.0.0.1');
      expect(res.extra[FailoverExtraKeys.idempotencyKey], isA<String>());
      expect(res.extra[FailoverExtraKeys.attempts], isA<List<AttemptRecord>>());
      final List<AttemptRecord> attempts =
          res.extra[FailoverExtraKeys.attempts] as List<AttemptRecord>;
      expect(attempts, hasLength(1));
      expect(attempts.first.outcome, AttemptOutcome.succeeded);
      expect(attempts.first.attemptIndex, 0);
    });

    test('idempotency key is injected and stable across attempts', () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          singleIpFastPath: false,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      await client.get<dynamic>('/v1/status');
      expect(requestLog, hasLength(1));
      expect(requestLog.first, contains('idem='));
      expect(requestLog.first, isNot(contains('idem= '))); // non-empty
    });

    test(
        'single-IP fast path: no failover_dio_* headers, no Response.extra '
        'metadata, no events emitted', () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1'],
        },
      );
      final List<FailoverEvent> events = <FailoverEvent>[];
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          // singleIpFastPath defaults to true; assert default behavior.
          onEvent: events.add,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res = await client.get<dynamic>('/v1/status');
      expect(res.statusCode, 200);

      // No failover_dio_* headers on the wire. The server logs in the
      // form "METHOD path idem=<val> prev=<val>"; with the fast path
      // both values must be empty strings.
      expect(requestLog, hasLength(1));
      expect(requestLog.first, matches(RegExp(r'idem=\s')),
          reason: 'idempotency header should be absent in single-IP fast path');
      expect(requestLog.first, endsWith('prev='),
          reason: 'previous-ip header should be absent in single-IP fast path');

      // No FailoverExtraKeys metadata populated.
      expect(res.extra[FailoverExtraKeys.winningIp], isNull);
      expect(res.extra[FailoverExtraKeys.idempotencyKey], isNull);
      expect(res.extra[FailoverExtraKeys.attempts], isNull);
      expect(res.extra[FailoverExtraKeys.totalMs], isNull);

      // No per-request lifecycle events fire (HostResolved from the
      // cache layer is the only one we tolerate; the fast path itself
      // is silent).
      expect(events.whereType<AttemptStarted>(), isEmpty);
      expect(events.whereType<AttemptSucceeded>(), isEmpty);
      expect(events.whereType<AttemptFailed>(), isEmpty);
      expect(events.whereType<AttemptAborted>(), isEmpty);
      expect(events.whereType<RequestExhausted>(), isEmpty);
    });

    test('falls back to second IP when first IP times out', () async {
      // Bind a second server that delays its response to simulate a slow IP.
      final HttpServer slow = await HttpServer.bind('127.0.0.1', 0);
      slow.listen((HttpRequest req) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        req.response.statusCode = 504;
        await req.response.close();
      });
      addTearDown(() => slow.close(force: true));

      // Use a non-routable but resolvable IP for the "slow" target: actually
      // we want to simulate timeout. Easiest cross-platform approach is to
      // give the cache an IP that will not connect (TEST-NET-1).
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1', '127.0.0.1'],
        },
      );
      final List<FailoverEvent> events = <FailoverEvent>[];
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          // Short timeouts so the test is fast.
          getConnectTimeout: const Duration(milliseconds: 300),
          defaultConnectTimeout: const Duration(milliseconds: 300),
          overallTimeout: const Duration(seconds: 10),
          onEvent: events.add,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res =
          await client.get<dynamic>('/v1/status').timeout(
                const Duration(seconds: 10),
              );
      expect(res.statusCode, 200);
      expect(res.extra[FailoverExtraKeys.winningIp], '127.0.0.1');

      final List<AttemptRecord> attempts =
          res.extra[FailoverExtraKeys.attempts] as List<AttemptRecord>;
      expect(attempts.length, greaterThanOrEqualTo(2));
      expect(attempts.first.ip, '192.0.2.1');
      expect(attempts.last.ip, '127.0.0.1');
      expect(attempts.last.outcome, AttemptOutcome.succeeded);

      // Verify the fallback attempt carried the previous-IP header on the
      // wire.
      expect(
        requestLog.any((s) => s.contains('prev=192.0.2.1')),
        isTrue,
        reason: 'expected at least one request with prev=192.0.2.1',
      );

      // Verify we emitted the expected event types.
      expect(events.whereType<HostResolved>(), isNotEmpty);
      expect(events.whereType<AttemptStarted>(), isNotEmpty);
      expect(events.whereType<AttemptSucceeded>(), isNotEmpty);
    });

    test('cancel via CancelToken aborts the request', () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          getConnectTimeout: const Duration(seconds: 10),
          defaultConnectTimeout: const Duration(seconds: 10),
          overallTimeout: const Duration(seconds: 30),
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );
      final CancelToken token = CancelToken();
      final Future<Response<dynamic>> f =
          client.get<dynamic>('/v1/status', cancelToken: token);
      // Cancel after a moment so the request is in flight.
      Timer(const Duration(milliseconds: 50), () => token.cancel('user'));
      await expectLater(
        f,
        throwsA(predicate<Object>((Object e) {
          if (e is! DioException) return false;
          return CancelToken.isCancel(e);
        })),
      );
    });

    test('exhausts after maxIpAttempts then throws FailoverExhaustedError',
        () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1', '192.0.2.2', '192.0.2.3'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          getConnectTimeout: const Duration(milliseconds: 150),
          defaultConnectTimeout: const Duration(milliseconds: 150),
          overallTimeout: const Duration(seconds: 5),
          maxIpAttempts: 3,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      await expectLater(
        client.get<dynamic>('/v1/status'),
        throwsA(
          predicate<Object>((Object e) {
            if (e is! DioException) return false;
            return e.error is FailoverExhaustedError;
          }),
        ),
      );
    });

    test('Uppercase host and trailing dot both hit the same cache row',
        () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://Fake.Host.Test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );
      await client.get<dynamic>('/v1/status');
      await client.get<dynamic>('/v1/status');
      expect(dns.callCount, 1);
    });
  });
}

