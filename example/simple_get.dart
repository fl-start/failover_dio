// Minimal example: change the import from `package:dio/dio.dart` to
// `package:failover_dio/failover_dio.dart` and your existing code keeps
// working — but for HTTP hosts, requests now transparently fail over
// across DNS-resolved IPs when the first one is slow or unreachable.
//
// NOTE (v0.1): HTTPS targets fall back to the standard Dio adapter
// (no per-IP failover) because dart:io's `HttpClient.connectionFactory`
// cannot produce a SecureSocket-yielding `ConnectionTask<Socket>`
// (final class + invariant generics). HTTPS failover lands in v0.2 via
// a custom HTTP/1.1 transport.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  // neverssl.com is a public HTTP-only host maintained for testing
  // captive portals and similar scenarios — perfect for showing that
  // the failover adapter is wired in for plaintext HTTP traffic.
  final Dio dio = Dio(
    options: BaseOptions(baseUrl: 'http://neverssl.com'),
  );

  final Response<dynamic> res = await dio.get<dynamic>('/');
  print('status:     ${res.statusCode}');
  print('winning ip: ${res.extra[FailoverExtraKeys.winningIp]}');
  print('idem key:   ${res.extra[FailoverExtraKeys.idempotencyKey]}');
  print('total ms:   ${res.extra[FailoverExtraKeys.totalMs]}');
}
