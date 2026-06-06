// POST request example. Bodies are buffered up to `BodyReplayPolicy`'s
// limit (1MB default) so each fail-over IP attempt can send the same
// payload, and the server gets the same `failover_dio_idempotency_key`
// on every retry to deduplicate.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  final Dio dio = Dio(
    options: BaseOptions(baseUrl: 'https://httpbin.org'),
    failoverOptions: FailoverOptions(
      // Cap how long the whole logical request may take.
      overallTimeout: const Duration(seconds: 25),
      // Per-IP TCP connect race bound (Happy Eyeballs cold path).
      probeTimeout: const Duration(seconds: 2),
    ),
  );

  final Response<Map<String, dynamic>> res = await dio.post<Map<String, dynamic>>(
    '/post',
    data: <String, Object?>{'hello': 'world'},
    options: Options(contentType: 'application/json'),
  );
  print('status: ${res.statusCode}');
  print('echo  : ${res.data?["json"]}');
  print('on the wire the request carried these headers:');
  for (final dynamic h in (res.data?['headers'] as Map<String, dynamic>?)?.entries ?? <MapEntry<String, dynamic>>[]) {
    final MapEntry<String, dynamic> e = h as MapEntry<String, dynamic>;
    if (e.key.toLowerCase().startsWith('failover_dio_')) {
      print('  ${e.key}: ${e.value}');
    }
  }
}
