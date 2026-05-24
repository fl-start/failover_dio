import 'dart:io';

/// Pluggable latency probe used to estimate round-trip cost of each
/// candidate IP.
///
/// The default implementation, [TcpConnectProbe], opens a TCP connection
/// to the target IP and port and measures the time to the first SYN/ACK.
/// Custom implementations can do an HTTP HEAD probe, an ICMP-style ping
/// on platforms where it is available, or return cached telemetry.
abstract class LatencyProbe {
  /// Probes [ip] on [port] and returns the measured latency in ms.
  ///
  /// Returns `null` on probe failure or timeout.
  Future<int?> probe(InternetAddress ip, int port, {Duration? timeout});
}
