import 'package:dio/dio.dart' as dio;
import 'package:dio_web_adapter/dio_web_adapter.dart' as dio_web;

import '../config/failover_options.dart';
import '../latency/latency_probe.dart';
import '../observability/cache_inspector.dart';
import '../observability/failover_event.dart';
import '../util/metrics.dart';

/// Web fallback for the `Dio` class.
///
/// Web browsers do not allow code-level control over DNS resolution, IP
/// pinning, or SNI, so full failover cannot be implemented there. The web
/// build delegates to stock Dio so the public API stays identical and
/// callers don't need conditional imports.
class Dio extends dio_web.DioForBrowser {
  /// Creates a [Dio] with the given Dio [options]. [failoverOptions] is
  /// accepted for source compatibility but ignored on web.
  // ignore: avoid_unused_constructor_parameters, use_super_parameters
  Dio({dio.BaseOptions? options, FailoverOptions? failoverOptions})
      : super(options);
}

/// Web stub for [FailoverDio]. Static helpers are no-ops; the [Dio]
/// constructor still returns a working stock-Dio client.
class FailoverDio extends Dio {
  /// Creates a web `FailoverDio` (delegates to stock Dio).
  FailoverDio({super.options, super.failoverOptions});

  /// No-op on web.
  static void clearHostCache([String? host]) {}

  /// No-op on web.
  static Future<void> disposeSharedCache() async {}

  /// Empty snapshot on web.
  static CacheSnapshot inspectCache() =>
      const CacheSnapshot(hosts: <String, HostSnapshot>{});

  /// Returns no-op metrics on web.
  static FailoverMetrics metrics() => const NoOpFailoverMetrics();

  /// No-op on web.
  static Future<Map<String, WarmupResult>> warmup(
    List<String> hosts, {
    int port = 443,
    bool withProbe = true,
    FailoverOptions? options,
    LatencyProbe? probe,
  }) async =>
      <String, WarmupResult>{
        for (final String h in hosts)
          h: WarmupResult(host: h, ips: const <String>[], latencyMs: const <String, int?>{})
      };

  /// No events on web; returns an empty stream.
  static Stream<FailoverEvent> get events => const Stream<FailoverEvent>.empty();

  /// No-op on web.
  static void eventSink(FailoverEvent e) {}

  /// No-op on web.
  static Future<void> closeEvents() async {}
}

/// Result of a `FailoverDio.warmup` call for one host. Always empty on web.
class WarmupResult {
  /// Creates a result.
  const WarmupResult({
    required this.host,
    required this.ips,
    required this.latencyMs,
    this.error,
  });

  /// Normalized hostname.
  final String host;

  /// Resolved IPs (empty on web).
  final List<String> ips;

  /// Per-IP latency (empty on web).
  final Map<String, int?> latencyMs;

  /// Error captured (always null on web).
  final Object? error;

  /// Whether warmup completed without an error.
  bool get success => error == null;
}

/// Stub of the failover adapter class that exists in the io build only.
///
/// Re-exported here so callers don't have to write conditional imports.
class FailoverHttpClientAdapter {
  FailoverHttpClientAdapter._();
}

/// Stub of [HostIpCache] re-exported for symmetry with the io build.
class HostIpCache {
  HostIpCache._();
}
