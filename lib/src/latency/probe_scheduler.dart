import 'dart:async';

import '../cache/host_ip_cache.dart';
import '../cache/ip_entry.dart';
import '../config/failover_options.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../util/clock.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import 'latency_probe.dart';

/// Schedules background latency probes with:
///
/// - Recency dedup: skip IPs probed within `FailoverOptions.probeFreshness`.
/// - Concurrency budget: cap the number of in-flight probes per scheduler
///   at `FailoverOptions.maxConcurrentProbes`.
/// - Coalescing: concurrent triggers for the same `(host, ip)` collapse
///   into a single probe.
class ProbeScheduler {
  /// Creates a scheduler.
  ProbeScheduler({
    required this.probe,
    required this.cache,
    required this.options,
    Clock clock = const SystemClock(),
    FailoverLogger logger = const NoOpFailoverLogger(),
    void Function(FailoverEvent)? onEvent,
  })  : _clock = clock,
        _logger = logger,
        _onEvent = onEvent;

  /// The probe implementation.
  LatencyProbe probe;

  /// Cache where probe results are recorded.
  HostIpCache cache;

  /// Configuration (read live for limits).
  FailoverOptions options;

  final Clock _clock;
  final FailoverLogger _logger;
  final void Function(FailoverEvent)? _onEvent;

  int _inFlight = 0;
  final Map<String, Future<void>> _coalesce = <String, Future<void>>{};

  /// Returns the number of probes currently in flight.
  int get inFlight => _inFlight;

  /// Triggers probes for every IP under [host] that is eligible (fresh
  /// dedup window expired and not over the concurrency budget).
  ///
  /// Returns immediately; probes complete in the background.
  void maybeProbeAll(String host, {int port = 443}) {
    if (!options.enableLatencyProbeFor(host)) return;
    final List<IpEntry> entries =
        cache.orderedEntries(HostnameNormalizer.normalize(host));
    if (entries.length < 2) {
      // Per spec, probe only when more than one A/AAAA entry exists.
      return;
    }
    for (final IpEntry e in entries) {
      _scheduleOne(host, e, port);
    }
  }

  void _scheduleOne(String host, IpEntry entry, int port) {
    final String key = '${HostnameNormalizer.normalize(host)}|${entry.address.address}|$port';

    final DateTime? last = entry.lastProbedAt;
    if (last != null) {
      final Duration sinceLast = _clock.now().difference(last);
      if (sinceLast < options.probeFreshness) {
        FailoverMetrics.instance.incProbesDedupSkipped();
        return;
      }
    }
    if (_coalesce.containsKey(key)) {
      FailoverMetrics.instance.incProbesDedupSkipped();
      return;
    }
    if (_inFlight >= options.maxConcurrentProbes) {
      // Drop on the floor; next request will trigger again.
      return;
    }

    _inFlight++;
    FailoverMetrics.instance.incProbes();
    final Future<void> f = Future<void>(() async {
      int? latency;
      bool ok = false;
      try {
        latency = await probe.probe(entry.address, port,
            timeout: options.probeTimeout);
        ok = latency != null;
      } catch (e) {
        _logger.log(FailoverLogLevel.warn, 'probe_failed',
            fields: <String, Object?>{
              'host': host,
              'ip': entry.addressString,
              'error': e.toString(),
            });
      } finally {
        _inFlight--;
        unawaited(_coalesce.remove(key) ?? Future<void>.value());
      }
      cache.recordLatency(
        HostnameNormalizer.normalize(host),
        entry.address,
        latency,
      );
      _emit(LatencyProbed(
        host: HostnameNormalizer.normalize(host),
        ip: entry.addressString,
        latencyMs: latency,
        success: ok,
      ));
      _logger.log(FailoverLogLevel.trace, 'probe_done',
          fields: <String, Object?>{
            'host': host,
            'ip': entry.addressString,
            'ms': latency,
            'success': ok,
          });
    });
    _coalesce[key] = f;
  }

  /// Awaits all currently in-flight probes. Useful in tests.
  Future<void> drain() async {
    while (_coalesce.isNotEmpty) {
      await Future.wait<void>(_coalesce.values.toList(growable: false));
    }
  }

  void _emit(FailoverEvent e) {
    try {
      _onEvent?.call(e);
    } catch (_) {
      // Ignore subscriber failures.
    }
  }

  /// Awaits a single probe of [host]:[port] explicitly (used by warmup).
  Future<List<int?>> warmupProbe(String host, {int port = 443}) async {
    final List<IpEntry> entries =
        cache.orderedEntries(HostnameNormalizer.normalize(host));
    final List<int?> results = <int?>[];
    for (final IpEntry e in entries) {
      try {
        final int? ms =
            await probe.probe(e.address, port, timeout: options.probeTimeout);
        cache.recordLatency(host, e.address, ms);
        results.add(ms);
        _emit(LatencyProbed(
          host: HostnameNormalizer.normalize(host),
          ip: e.addressString,
          latencyMs: ms,
          success: ms != null,
        ));
      } catch (_) {
        results.add(null);
      }
    }
    return results;
  }
}
