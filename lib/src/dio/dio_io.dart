import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:dio/io.dart' as dio_io;

import '../adapter/failover_http_client_adapter.dart';
import '../cache/host_ip_cache.dart';
import '../cache/ip_entry.dart';
import '../config/failover_options.dart';
import '../latency/latency_probe.dart';
import '../observability/cache_inspector.dart';
import '../observability/failover_event.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import '../websocket/websocket_export.dart';

/// Drop-in replacement for `dio.Dio` that installs the
/// [FailoverHttpClientAdapter] in its constructor.
///
/// `class Dio extends dio.DioForNative` is the supported way to subclass
/// Dio (its primary constructor is a factory). All Dio behavior is
/// inherited unchanged; only the network transport is swapped.
class Dio extends dio_io.DioForNative {
  /// Creates a [Dio] with the given Dio [options] and an optional
  /// [failoverOptions] overlay.
  Dio({dio.BaseOptions? options, FailoverOptions? failoverOptions})
      : _adapter =
            FailoverHttpClientAdapter(options: failoverOptions),
        super(options) {
    httpClientAdapter = _adapter;
  }

  final FailoverHttpClientAdapter _adapter;

  /// Returns the underlying failover adapter (e.g. to inspect its cache).
  FailoverHttpClientAdapter get failoverAdapter => _adapter;
}

/// Static helpers and convenience entry point.
///
/// `FailoverDio` is also a class; you can use either `Dio` or `FailoverDio`
/// to instantiate the failover-aware client. The static members operate on
/// the shared singleton cache and on a process-wide event stream.
class FailoverDio extends Dio {
  /// Creates a [FailoverDio].
  FailoverDio({super.options, super.failoverOptions});

  /// Opens a WebSocket with DNS-aware connect + reconnect failover.
  ///
  /// Delegates to [FailoverWebSocket.connect] using this client's
  /// [failoverAdapter] cache when [failoverOptions.useSharedCache] is true.
  static Future<FailoverWebSocket> connectWebSocket(
    String url, {
    FailoverOptions? failoverOptions,
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) {
    return FailoverWebSocket.connect(
      url,
      failoverOptions: failoverOptions,
      protocols: protocols,
      headers: headers,
    );
  }

  /// Wipes the entire shared cache, or only [host] if supplied.
  static void clearHostCache([String? host]) {
    HostIpCache.clearShared(host == null
        ? null
        : HostnameNormalizer.normalize(host));
  }

  /// Tears down the shared cache singleton (cancels probes, releases
  /// timers). Useful in test teardown and short-lived CLI tools.
  static Future<void> disposeSharedCache() => HostIpCache.disposeShared();

  /// Returns an immutable snapshot of the shared cache for debugging.
  static CacheSnapshot inspectCache() {
    final HostIpCache? c = HostIpCache.shared;
    if (c == null) return const CacheSnapshot(hosts: <String, HostSnapshot>{});
    return c.snapshot();
  }

  /// Returns metrics aggregated by the library.
  static FailoverMetrics metrics() => FailoverMetrics.instance;

  /// Pre-resolves DNS and (optionally) probes latency for [hosts] before
  /// any real traffic. Useful from a splash screen or app launch path.
  ///
  /// [port] defaults to 443. Pass [withProbe] = false to skip the probes.
  static Future<Map<String, WarmupResult>> warmup(
    List<String> hosts, {
    int port = 443,
    bool withProbe = true,
    FailoverOptions? options,
    LatencyProbe? probe,
  }) async {
    final FailoverOptions opts = options ?? FailoverOptions();
    final FailoverHttpClientAdapter adapter = FailoverHttpClientAdapter(
      options: opts,
      probe: probe,
    );
    final Map<String, WarmupResult> out = <String, WarmupResult>{};
    for (final String raw in hosts) {
      final String host = HostnameNormalizer.normalize(raw);
      try {
        final List<IpEntry> entries =
            await adapter.cache.resolveIfNeeded(host);
        final List<String> ips =
            entries.map((IpEntry e) => e.addressString).toList(growable: false);
        final Map<String, int?> latency = <String, int?>{};
        if (withProbe && entries.length > 1) {
          final List<int?> ls =
              await adapter.probeScheduler.warmupProbe(host, port: port);
          for (int i = 0; i < entries.length && i < ls.length; i++) {
            latency[entries[i].addressString] = ls[i];
          }
        }
        out[host] = WarmupResult(host: host, ips: ips, latencyMs: latency);
      } catch (e) {
        out[host] = WarmupResult(
          host: host,
          ips: const <String>[],
          latencyMs: const <String, int?>{},
          error: e,
        );
      }
    }
    return out;
  }

  /// Broadcast stream of typed [FailoverEvent]s.
  ///
  /// **Note:** events are only delivered for `Dio` instances that were
  /// constructed with `FailoverOptions(onEvent: FailoverDio.eventSink)`
  /// (or another callback that forwards here).
  static Stream<FailoverEvent> get events => _events.stream;

  /// Sink that app code can pass as `onEvent` to forward all events to the
  /// shared [events] stream.
  static void eventSink(FailoverEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// Closes the process-wide events stream. Call only from final shutdown.
  static Future<void> closeEvents() => _events.close();

  static final StreamController<FailoverEvent> _events =
      StreamController<FailoverEvent>.broadcast();
}

/// Result of a `FailoverDio.warmup` call for one host.
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

  /// Resolved IPs for the host.
  final List<String> ips;

  /// Per-IP measured latency (ms); empty when probes were skipped.
  final Map<String, int?> latencyMs;

  /// Error captured during resolution or probing.
  final Object? error;

  /// Whether warmup completed without an error.
  bool get success => error == null;
}
