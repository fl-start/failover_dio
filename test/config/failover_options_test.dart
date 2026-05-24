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
  });
}
