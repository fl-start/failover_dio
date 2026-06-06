import 'dart:io';

import 'happy_eyeballs_probe.dart';

/// Pluggable latency probe used to estimate TCP connect cost of each
/// candidate IP.
///
/// The default implementation, [TcpConnectProbe], opens a TCP connection
/// to the target IP and port and measures handshake time. Probes are
/// orchestrated in parallel by [HappyEyeballsProbe] (Happy Eyeballs
/// algorithm): all connects start together, completions reorder the cache
/// immediately, and HTTP proceeds after the first arrival without waiting
/// for slower peers.
///
/// Custom implementations can do an HTTP HEAD probe or return cached
/// telemetry.
abstract class LatencyProbe {
  /// Probes [ip] on [port] and returns the measured latency in ms.
  ///
  /// Returns `null` on probe failure or timeout.
  Future<int?> probe(InternetAddress ip, int port, {Duration? timeout});
}
