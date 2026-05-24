import 'dart:async';
import 'dart:io';

import 'latency_probe.dart';

/// Default latency probe that times a single TCP connect to [InternetAddress].
///
/// Pros: works on every Dart platform that supports `dart:io Socket`;
/// approximates real connect cost.
/// Cons: not actual application-layer RTT.
class TcpConnectProbe implements LatencyProbe {
  /// Creates a TCP-connect probe.
  const TcpConnectProbe({this.defaultTimeout = const Duration(seconds: 2)});

  /// Per-probe timeout when the caller does not pass one.
  final Duration defaultTimeout;

  @override
  Future<int?> probe(InternetAddress ip, int port, {Duration? timeout}) async {
    final Duration t = timeout ?? defaultTimeout;
    final Stopwatch sw = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port).timeout(t);
      sw.stop();
      return sw.elapsedMilliseconds;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        // Ignore; probe is best-effort.
      }
    }
  }
}
