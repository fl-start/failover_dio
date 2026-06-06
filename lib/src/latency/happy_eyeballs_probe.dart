import 'dart:async';

import '../cache/ip_entry.dart';
import 'latency_probe.dart';

/// Outcome of one IP in a Happy Eyeballs TCP-connect race.
class HappyEyeballsProbeResult {
  /// Creates a result.
  const HappyEyeballsProbeResult({
    required this.entry,
    required this.latencyMs,
    required this.completionOrder,
  });

  /// The probed cache entry.
  final IpEntry entry;

  /// Measured TCP connect time in ms, or `null` on failure/timeout.
  final int? latencyMs;

  /// Zero-based finish order (0 = first TCP handshake to complete).
  final int completionOrder;
}

/// Parallel TCP-connect latency measurement using the Happy Eyeballs
/// pattern.
///
/// Every candidate IP is probed **concurrently**. [onResult] fires as soon
/// as each individual connect attempt finishes — the caller is never
/// blocked waiting for the slowest peer. The returned future completes when
/// the **first** probe in the batch finishes (success or failure); any
/// slower probes keep running until they complete or hit [timeout].
class HappyEyeballsProbe {
  /// Creates a racer backed by [probe].
  const HappyEyeballsProbe({required this.probe});

  /// Underlying single-IP probe implementation.
  final LatencyProbe probe;

  /// Starts a parallel TCP-connect race across [entries].
  ///
  /// Returns the first [HappyEyeballsProbeResult] to finish. Remaining
  /// probes continue in the background and invoke [onResult] as they land.
  Future<HappyEyeballsProbeResult?> race({
    required List<IpEntry> entries,
    required int port,
    required Duration timeout,
    required void Function(HappyEyeballsProbeResult result) onResult,
  }) async {
    if (entries.isEmpty) return null;

    final Completer<HappyEyeballsProbeResult?> firstFinished =
        Completer<HappyEyeballsProbeResult?>();
    int completionOrder = 0;

    for (final IpEntry entry in entries) {
      unawaited(_probeOne(
        entry: entry,
        port: port,
        timeout: timeout,
        onResult: onResult,
        assignOrder: () => completionOrder++,
        firstFinished: firstFinished,
      ));
    }

    return firstFinished.future;
  }

  /// Like [race], but the returned future does not complete until every
  /// probe in [entries] has finished. Used by warmup.
  Future<List<HappyEyeballsProbeResult>> raceAll({
    required List<IpEntry> entries,
    required int port,
    required Duration timeout,
    required void Function(HappyEyeballsProbeResult result) onResult,
  }) async {
    if (entries.isEmpty) return const <HappyEyeballsProbeResult>[];

    final List<HappyEyeballsProbeResult> results =
        <HappyEyeballsProbeResult>[];
    int completionOrder = 0;
    final List<Future<void>> pending = <Future<void>>[];

    for (final IpEntry entry in entries) {
      pending.add(_probeOne(
        entry: entry,
        port: port,
        timeout: timeout,
        onResult: (HappyEyeballsProbeResult r) {
          onResult(r);
          results.add(r);
        },
        assignOrder: () => completionOrder++,
        firstFinished: null,
      ));
    }

    await Future.wait<void>(pending);
    results.sort((HappyEyeballsProbeResult a, HappyEyeballsProbeResult b) =>
        a.completionOrder.compareTo(b.completionOrder));
    return results;
  }

  Future<void> _probeOne({
    required IpEntry entry,
    required int port,
    required Duration timeout,
    required void Function(HappyEyeballsProbeResult result) onResult,
    required int Function() assignOrder,
    required Completer<HappyEyeballsProbeResult?>? firstFinished,
  }) async {
    final int? latencyMs =
        await probe.probe(entry.address, port, timeout: timeout);
    final HappyEyeballsProbeResult result = HappyEyeballsProbeResult(
      entry: entry,
      latencyMs: latencyMs,
      completionOrder: assignOrder(),
    );
    onResult(result);
    if (firstFinished != null && !firstFinished.isCompleted) {
      firstFinished.complete(result);
    }
  }
}
