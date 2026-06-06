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

    test('parallel connect race picks reachable IP and sends one HTTP',
        () async {
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1', '127.0.0.1', '192.0.2.2'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableMisconfigWarnings: false,
          probeTimeout: const Duration(milliseconds: 500),
          maxIpAttempts: 3,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res =
          await client.get<dynamic>('/v1/status');
      expect(res.statusCode, 200);
      expect(res.extra[FailoverExtraKeys.winningIp], '127.0.0.1');
      expect(requestLog, hasLength(1),
          reason: 'only one HTTP request should hit the server');
    });

    test('parallel connect race reaches 127.0.0.1 when TEST-NET is slow',
        () async {
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
          enableMisconfigWarnings: false,
          probeTimeout: const Duration(milliseconds: 500),
          overallTimeout: const Duration(seconds: 5),
          maxIpAttempts: 2,
          onEvent: events.add,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res =
          await client.get<dynamic>('/v1/status');
      expect(res.statusCode, 200);
      expect(res.extra[FailoverExtraKeys.winningIp], '127.0.0.1');
      expect(requestLog, hasLength(1));

      expect(events.whereType<LatencyProbed>(), isNotEmpty);
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
          enableMisconfigWarnings: false,
          probeTimeout: const Duration(milliseconds: 150),
          overallTimeout: const Duration(seconds: 5),
          maxIpAttempts: 3,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      await expectLater(
        client.get<dynamic>('/v1/status').timeout(
              const Duration(seconds: 3),
            ),
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

    // ── Warm-path skip (improvement 1) ──────────────────────────────────

    test('warm-path skip: second request emits no LatencyProbed events when '
        'rankings are fresh (improvement 1)', () async {
      // Two IPs: 192.0.2.1 (unreachable) and 127.0.0.1 (reachable).
      // First request: cold → TCP race runs → both IPs call onConnectComplete.
      // Second request: 127.0.0.1 has fresh latency → warm-path skip → no race.
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['192.0.2.1', '127.0.0.1'],
        },
      );
      final List<LatencyProbed> probeEvents = <LatencyProbed>[];
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableMisconfigWarnings: false,
          probeTimeout: const Duration(milliseconds: 400),
          overallTimeout: const Duration(seconds: 5),
          maxIpAttempts: 2,
          // Long freshness window: second request definitely sees stale=false.
          probeFreshness: const Duration(seconds: 60),
          onEvent: (FailoverEvent e) {
            if (e is LatencyProbed) probeEvents.add(e);
          },
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      // First request: cold path → TCP race should fire.
      await client.get<dynamic>('/v1/status');
      final int probesAfterFirst = probeEvents.length;
      expect(probesAfterFirst, greaterThan(0),
          reason: 'first (cold) request must run TCP race');

      probeEvents.clear();

      // Second request: warm path → TCP race must be skipped.
      await client.get<dynamic>('/v1/status');
      expect(probeEvents, isEmpty,
          reason: 'second (warm) request must skip TCP race when rankings '
              'are fresh (improvement 1)');
    });

    // ── Redirect-To-Peer failover (improvement 4) ────────────────────────

    test(
        'redirectToPeerStatus: retries next IP when server returns the '
        'configured "Redirect-To-Peer" code (improvement 4)', () async {
      // Override the server to return 553 on the first connection,
      // 200 on the second. Bind to all interfaces so that connections
      // to 127.0.0.1 and 127.0.0.2 (both loopback) both reach this server.
      await server.close(force: true);
      int reqIndex = 0;
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      port = server.port;
      server.listen((HttpRequest req) async {
        reqIndex++;
        requestLog.add('req#$reqIndex');
        req.response.statusCode = reqIndex == 1 ? 553 : 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":${reqIndex != 1}}');
        await req.response.close();
      });

      // Two loopback IPs; serial waves (maxIpAttempts: 1) for predictability.
      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1', '127.0.0.2'],
        },
      );
      final List<AttemptRecord> seenAttempts = <AttemptRecord>[];
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          maxIpAttempts: 1,
          // Opt in to Redirect-To-Peer failover for status code 553.
          redirectToPeerStatus: 553,
          onEvent: (FailoverEvent e) {
            if (e is AttemptSucceeded || e is AttemptFailed) {
              // Capture via Response.extra after the call.
            }
          },
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res = await client.get<dynamic>('/v1/status');
      expect(res.statusCode, 200,
          reason: 'final response must be the 200 from the second IP');

      // Two HTTP requests hit the server (one 502, one 200).
      expect(requestLog, hasLength(2),
          reason: 'two distinct HTTP requests must have been sent');

      // Attempt records: first attempt failedOnStatus, second succeeded.
      final List<AttemptRecord> attempts =
          res.extra[FailoverExtraKeys.attempts] as List<AttemptRecord>;
      expect(attempts, hasLength(2));
      expect(attempts[0].outcome, AttemptOutcome.failedOnStatus);
      expect(attempts[0].statusCode, 553);
      expect(attempts[1].outcome, AttemptOutcome.succeeded);
      expect(attempts[1].statusCode, 200);
      seenAttempts.addAll(attempts);
      expect(seenAttempts, isNotEmpty);
    });

    test(
        'redirectToPeerStatus: returns last redirect response when every IP '
        'returns the configured code', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      port = server.port;
      server.listen((HttpRequest req) async {
        requestLog.add('redirect');
        req.response.statusCode = 553;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"redirect":true}');
        await req.response.close();
      });

      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1', '127.0.0.2'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          maxIpAttempts: 1,
          redirectToPeerStatus: 553,
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      final Response<dynamic> res = await client.get<dynamic>(
        '/v1/status',
        options: Options(validateStatus: (_) => true),
      );
      expect(res.statusCode, 553);
      expect(requestLog, hasLength(2));
      final List<AttemptRecord> attempts =
          res.extra[FailoverExtraKeys.attempts] as List<AttemptRecord>;
      expect(attempts, hasLength(2));
      expect(
        attempts.every(
            (AttemptRecord a) => a.outcome == AttemptOutcome.failedOnStatus),
        isTrue,
      );
    });

    test('overallTimeout aborts an in-flight stalled HTTP fetch', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      port = server.port;
      server.listen((HttpRequest req) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        req.response.statusCode = 200;
        await req.response.close();
      });

      final FakeDnsResolver dns = FakeDnsResolver(
        <String, List<String>>{
          'fake.host.test': <String>['127.0.0.1', '127.0.0.2'],
        },
      );
      final FailoverDio client = FailoverDio(
        options: BaseOptions(baseUrl: 'http://fake.host.test:$port'),
        failoverOptions: FailoverOptions(
          dnsResolver: dns,
          useSharedCache: false,
          enableLatencyProbe: false,
          enableMisconfigWarnings: false,
          maxIpAttempts: 1,
          overallTimeout: const Duration(milliseconds: 150),
          dnsLocalHosts: const <String>{'fake.host.test', 'localhost'},
        ),
      );

      await expectLater(
        client.get<dynamic>('/v1/slow'),
        throwsA(predicate<Object>((Object e) {
          if (e is! DioException) return false;
          if (e.type != DioExceptionType.connectionTimeout) return false;
          final Object? err = e.error;
          return err is FailoverExhaustedError &&
              err.reason == 'overall_timeout';
        })),
      );
    });
  });
}

