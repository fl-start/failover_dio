// Warm up DNS and latency probes for a list of hosts before the first
// real request. Useful from a splash screen or app launch.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  final Map<String, WarmupResult> results = await FailoverDio.warmup(
    <String>['example.com', 'cloudflare.com'],
  );

  for (final MapEntry<String, WarmupResult> e in results.entries) {
    final WarmupResult r = e.value;
    if (r.success) {
      print('${e.key}: ${r.ips.length} IP(s), latency=${r.latencyMs}');
    } else {
      print('${e.key}: failed (${r.error})');
    }
  }
}
