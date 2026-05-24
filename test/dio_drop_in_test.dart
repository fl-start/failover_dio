import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('Dio drop-in (smoke)', () {
    test('Dio() constructs and has standard API', () {
      final client = Dio();
      expect(client.options, isA<BaseOptions>());
      expect(client.interceptors, isNotNull);
      expect(client.httpClientAdapter, isA<HttpClientAdapter>());
    });

    test('FailoverDio() is a Dio', () {
      final client = FailoverDio();
      expect(client, isA<Dio>());
    });

    test('FailoverDio with options', () {
      final client = FailoverDio(
        options: BaseOptions(baseUrl: 'https://api.example.com'),
        failoverOptions: FailoverOptions(maxIpAttempts: 2, useSharedCache: false),
      );
      expect(client.options.baseUrl, 'https://api.example.com');
      expect(client.failoverAdapter.options.maxIpAttempts, 2);
    });

    test('FailoverDio.clearHostCache is callable', () {
      // Should not throw whether the singleton exists or not.
      FailoverDio.clearHostCache();
      FailoverDio.clearHostCache('api.example.com');
    });

    test('FailoverDio.inspectCache returns a snapshot', () {
      final snap = FailoverDio.inspectCache();
      expect(snap, isA<CacheSnapshot>());
    });

    test('CancelToken from dio package works', () {
      final t = CancelToken();
      expect(t.isCancelled, isFalse);
      t.cancel('test');
      expect(t.isCancelled, isTrue);
      expect(CancelToken.isCancel(DioException.requestCancelled(
        requestOptions: RequestOptions(path: '/'),
        reason: 'test',
        stackTrace: StackTrace.current,
      )), isTrue);
    });

    test('Standard Dio types are re-exported', () {
      expect(BaseOptions, isNotNull);
      expect(RequestOptions, isNotNull);
      expect(Response, isNotNull);
      expect(DioException, isNotNull);
      expect(DioExceptionType, isNotNull);
    });
  });

  group('FailoverHeaders constants', () {
    test('header names match spec', () {
      expect(FailoverHeaders.idempotencyKey, 'failover_dio_idempotency_key');
      expect(FailoverHeaders.previousIp, 'failover_dio_previous_ip');
    });
  });
}
