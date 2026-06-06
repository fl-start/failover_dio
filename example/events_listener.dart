// Hook into FailoverDio's event stream for observability — log to Sentry,
// Datadog, or your own telemetry pipeline.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  // Subscribe before constructing the Dio so we don't miss the initial
  // resolve event.
  final subscription = FailoverDio.events.listen((FailoverEvent e) {
    switch (e) {
      case HostResolved():
        print('resolved ${e.host} → ${e.ips} (ttl=${e.ttl.inSeconds}s)');
      case AttemptStarted():
        print('attempt ${e.attemptIndex} → ${e.host} @ ${e.ip}'
            '${e.previousIp == null ? "" : " (after ${e.previousIp})"}');
      case AttemptSucceeded():
        print('  success in ${e.durationMs}ms (status=${e.statusCode})');
      case AttemptFailed():
        print('  failed in ${e.durationMs}ms: ${e.error}');
      case AttemptAborted():
        print('  aborted: ${e.reason.name}');
      case LatencyProbed():
        print('probe ${e.ip} = ${e.latencyMs}ms (ok=${e.success})');
      case IpMarkedUnavailable():
        print('marked unavailable ${e.host}/${e.ip} until ${e.until}');
      case CacheRefreshed():
        print('cache refresh ${e.host}: ${e.ipsBefore} → ${e.ipsAfter}');
      case CacheEvicted():
        print('cache evicted ${e.host} (${e.reason})');
      case RequestExhausted():
        print('REQUEST EXHAUSTED ${e.host} after ${e.attempts.length} attempts');
      case WebSocketConnected():
        print('ws connected ${e.host} @ ${e.ip}');
      case WebSocketReconnecting():
        print('ws reconnecting ${e.host} @ ${e.ip} (${e.phase})');
      case WebSocketReconnected():
        print('ws reconnected ${e.host} @ ${e.ip} (${e.phase})');
      case WebSocketReconnectFailed():
        print('ws reconnect failed ${e.host} @ ${e.ip}: ${e.error}');
    }
  });

  final Dio dio = Dio(
    failoverOptions: FailoverOptions(onEvent: FailoverDio.eventSink),
  );
  // HTTP target so the v0.1 failover path runs (HTTPS bypasses to stock
  // Dio in v0.1; see CHANGELOG / README "Limitations").
  await dio.get<dynamic>('http://neverssl.com/');

  await subscription.cancel();
  await FailoverDio.closeEvents();
}
