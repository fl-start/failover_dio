// Use FailoverDio.inspectCache() to inspect the live DNS + latency state
// for debugging.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  final Dio dio = Dio();
  // HTTP targets so the cache is populated by the failover adapter
  // (HTTPS bypasses to stock Dio in v0.1; see README "Limitations").
  await dio.get<dynamic>('http://neverssl.com/');
  await dio.get<dynamic>('http://httpforever.com/');

  final CacheSnapshot snap = FailoverDio.inspectCache();
  print(snap);
}
