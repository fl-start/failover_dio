import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('FailoverOptions', () {
    test('defaults are sane', () {
      final opts = FailoverOptions();
      expect(opts.getConnectTimeout, const Duration(seconds: 3));
      expect(opts.defaultConnectTimeout, const Duration(seconds: 8));
      expect(opts.overallTimeout, const Duration(seconds: 30));
      expect(opts.maxIpAttempts, 3);
      expect(opts.useSharedCache, isTrue);
      expect(opts.allowPrivateAddresses, isTrue);
      expect(opts.enableLatencyProbe, isTrue);
      expect(opts.enableFailoverHeaders, isTrue);
      // New defaults.
      expect(opts.latencyBucketMs, 10);
      expect(opts.redirectToPeerStatus, isNull);
    });

    test('copyWith overrides only set fields', () {
      final opts = FailoverOptions(maxIpAttempts: 5);
      final updated = opts.copyWith(maxIpAttempts: 2);
      expect(updated.maxIpAttempts, 2);
      expect(updated.useSharedCache, opts.useSharedCache);
    });

    test('per-host override returns inherited globals for unset fields', () {
      final opts = FailoverOptions(
        defaultConnectTimeout: const Duration(seconds: 10),
        perHost: const <String, HostOverride>{
          'api.internal.example.com': HostOverride(
            getConnectTimeout: Duration(milliseconds: 500),
            maxIpAttempts: 5,
          ),
        },
      );
      // Overridden field
      expect(opts.getConnectTimeoutFor('api.internal.example.com'),
          const Duration(milliseconds: 500));
      // Inherited field
      expect(opts.defaultConnectTimeoutFor('api.internal.example.com'),
          const Duration(seconds: 10));
      // Overridden int
      expect(opts.maxIpAttemptsFor('api.internal.example.com'), 5);
      // Other host gets global defaults
      expect(opts.getConnectTimeoutFor('cdn.example.com'),
          const Duration(seconds: 3));
    });

    test('per-host lookup is case-insensitive', () {
      final opts = FailoverOptions(
        perHost: const <String, HostOverride>{
          'api.example.com': HostOverride(maxIpAttempts: 7),
        },
      );
      expect(opts.maxIpAttemptsFor('API.Example.COM'), 7);
      expect(opts.maxIpAttemptsFor('api.example.com.'), 7);
    });

    test('copyWith preserves new fields when not overridden', () {
      final opts = FailoverOptions(
        latencyBucketMs: 25,
        redirectToPeerStatus: 553,
      );
      final copy = opts.copyWith(maxIpAttempts: 5);
      expect(copy.latencyBucketMs, 25);
      expect(copy.redirectToPeerStatus, 553);
    });

    test('copyWith can clear redirectToPeerStatus by passing null', () {
      final opts = FailoverOptions(redirectToPeerStatus: 553);
      final copy = opts.copyWith(redirectToPeerStatus: null);
      expect(copy.redirectToPeerStatus, isNull);
    });

    test(
        'per-host override applies latencyBucketMs and redirectToPeerStatus',
        () {
      final opts = FailoverOptions(
        latencyBucketMs: 10,
        perHost: const <String, HostOverride>{
          'gateway.example.com': HostOverride(
            latencyBucketMs: 50,
            redirectToPeerStatus: 553,
          ),
        },
      );
      // Override values for the specific host.
      expect(opts.latencyBucketMsFor('gateway.example.com'), 50);
      expect(opts.redirectToPeerStatusFor('gateway.example.com'), 553);
      // Global defaults for other hosts.
      expect(opts.latencyBucketMsFor('other.example.com'), 10);
      expect(opts.redirectToPeerStatusFor('other.example.com'), isNull);
    });
  });
}
