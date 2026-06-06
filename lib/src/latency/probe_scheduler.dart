import 'dart:async';

import '../cache/host_ip_cache.dart';
import '../cache/ip_entry.dart';
import '../config/failover_options.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../util/clock.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import 'happy_eyeballs_probe.dart';
import 'latency_probe.dart';

/// Schedules Happy Eyeballs parallel TCP-connect latency races.
///
/// For each host with more than one cached IP:
///
/// - **All** eligible TCP connects are started in parallel (Happy Eyeballs).
/// - Each completion immediately updates the cache sort order via
///   [HostIpCache.recordLatency] — faster arrivals bubble to the top
///   without waiting for slower peers.
/// - Callers awaiting [raceHappyEyeballs] unblock when the **first**
///   connect finishes; remaining probes continue in the background.
/// - Recency dedup: IPs probed within [FailoverOptions.probeFreshness] are
///   skipped until the window expires.
/// - Per-host coalescing: concurrent triggers for the same host join one
///   in-flight race.
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
        _onEvent = onEvent,
        _happyEyeballs = HappyEyeballsProbe(probe: probe);

  /// The probe implementation.
  LatencyProbe probe;

  /// Cache where probe results are recorded.
  HostIpCache cache;

  /// Configuration (read live for limits).
  FailoverOptions options;

  final Clock _clock;
  final FailoverLogger _logger;
  final void Function(FailoverEvent)? _onEvent;
  final HappyEyeballsProbe _happyEyeballs;

  int _inFlight = 0;

  /// Per-host in-flight Happy Eyeballs races (coalesced).
  final Map<String, Future<void>> _hostRaces = <String, Future<void>>{};

  /// Background probe batches still running after the first completion.
  final Map<String, Future<void>> _hostRaceDrain = <String, Future<void>>{};

  /// Returns the number of probes currently in flight.
  int get inFlight => _inFlight;

  /// Returns `true` when [entries] already carry at least one fresh,
  /// successful latency measurement usable for IP ordering.
  bool hasFreshLatencyRanking(Iterable<IpEntry> entries) {
    final DateTime now = _clock.now();
    for (final IpEntry e in entries) {
      final DateTime? last = e.lastProbedAt;
      if (last == null || e.latencyMs == null) continue;
      if (now.difference(last) < options.probeFreshness) {
        return true;
      }
    }
    return false;
  }

  /// Starts (or joins) a Happy Eyeballs parallel TCP-connect race for
  /// [host] on [port].
  ///
  /// All eligible IPs are probed concurrently. The returned future completes
  /// when the **first** connect attempt finishes — not when the full roster
  /// is measured. Slower probes keep running and update the cache as they
  /// land.
  ///
  /// If every IP was probed recently ([FailoverOptions.probeFreshness]),
  /// returns immediately.
  Future<void> raceHappyEyeballs(String host, {required int port}) {
    final String h = HostnameNormalizer.normalize(host);
    if (!options.enableLatencyProbeFor(h)) {
      return Future<void>.value();
    }

    final Future<void>? existing = _hostRaces[h];
    if (existing != null) return existing;

    final Future<void> race = _runHappyEyeballsRace(h, port);
    _hostRaces[h] = race;
    return race.whenComplete(() => _hostRaces.remove(h));
  }

  /// Fire-and-forget alias kept for adapter readability.
  void maybeProbeAll(String host, {int port = 443}) {
    unawaited(raceHappyEyeballs(host, port: port));
  }

  Future<void> _runHappyEyeballsRace(String host, int port) async {
    final List<IpEntry> entries = cache.orderedEntries(host);
    if (entries.length < 2) return;

    final List<IpEntry> eligible = _eligibleEntries(entries);
    if (eligible.isEmpty) {
      FailoverMetrics.instance.incProbesDedupSkipped();
      return;
    }

    _inFlight += eligible.length;
    FailoverMetrics.instance.incProbes();

    final Completer<void> allDone = Completer<void>();
    int remaining = eligible.length;

    void onProbeResult(HappyEyeballsProbeResult result) {
      cache.recordLatency(host, result.entry.address, result.latencyMs);
      _emit(LatencyProbed(
        host: host,
        ip: result.entry.addressString,
        latencyMs: result.latencyMs,
        success: result.latencyMs != null,
        completionOrder: result.completionOrder,
      ));
      _logger.log(FailoverLogLevel.trace, 'happy_eyeballs_probe_done',
          fields: <String, Object?>{
            'host': host,
            'ip': result.entry.addressString,
            'ms': result.latencyMs,
            'order': result.completionOrder,
            'success': result.latencyMs != null,
          });

      remaining--;
      if (remaining == 0 && !allDone.isCompleted) {
        allDone.complete();
      }
    }

    _hostRaceDrain[host] = allDone.future.whenComplete(() {
      _hostRaceDrain.remove(host);
      _inFlight -= eligible.length;
    });

    try {
      await _happyEyeballs.race(
        entries: eligible,
        port: port,
        timeout: options.probeTimeout,
        onResult: onProbeResult,
      );
    } catch (e) {
      if (!allDone.isCompleted) {
        _inFlight -= eligible.length;
        allDone.complete();
      }
      rethrow;
    }
  }

  List<IpEntry> _eligibleEntries(List<IpEntry> entries) {
    final DateTime now = _clock.now();
    final List<IpEntry> eligible = <IpEntry>[];
    for (final IpEntry e in entries) {
      final DateTime? last = e.lastProbedAt;
      if (last != null && now.difference(last) < options.probeFreshness) {
        FailoverMetrics.instance.incProbesDedupSkipped();
        continue;
      }
      eligible.add(e);
    }
    return eligible;
  }

  /// Awaits all currently in-flight probes. Useful in tests.
  Future<void> drain() async {
    while (_hostRaces.isNotEmpty || _hostRaceDrain.isNotEmpty) {
      final List<Future<void>> pending = <Future<void>>[
        ..._hostRaces.values,
        ..._hostRaceDrain.values,
      ];
      if (pending.isEmpty) break;
      await Future.wait<void>(pending);
    }
  }

  void _emit(FailoverEvent e) {
    try {
      _onEvent?.call(e);
    } catch (_) {
      // Ignore subscriber failures.
    }
  }

  /// Awaits a full parallel probe of every IP under [host] (warmup).
  Future<List<int?>> warmupProbe(String host, {int port = 443}) async {
    final String h = HostnameNormalizer.normalize(host);
    final List<IpEntry> entries = cache.orderedEntries(h);
    if (entries.isEmpty) return const <int?>[];

    _inFlight += entries.length;
    FailoverMetrics.instance.incProbes();

    final List<int?> results = <int?>[];
    try {
      await _happyEyeballs.raceAll(
        entries: entries,
        port: port,
        timeout: options.probeTimeout,
        onResult: (HappyEyeballsProbeResult result) {
          cache.recordLatency(h, result.entry.address, result.latencyMs);
          results.add(result.latencyMs);
          _emit(LatencyProbed(
            host: h,
            ip: result.entry.addressString,
            latencyMs: result.latencyMs,
            success: result.latencyMs != null,
            completionOrder: result.completionOrder,
          ));
        },
      );
    } finally {
      _inFlight -= entries.length;
    }
    return results;
  }
}
