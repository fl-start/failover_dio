// CancelToken works identically to stock Dio. Cancelling aborts every
// in-flight IP attempt and skips any remaining ones.

// ignore_for_file: avoid_print

import 'dart:async';

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  final Dio dio =
      Dio(options: BaseOptions(baseUrl: 'https://httpbin.org'));
  final CancelToken token = CancelToken();

  // Cancel after 500ms regardless of how the request is progressing.
  Timer(const Duration(milliseconds: 500), () => token.cancel('too slow'));

  try {
    final Response<dynamic> res =
        await dio.get<dynamic>('/delay/5', cancelToken: token);
    print('unexpectedly succeeded: ${res.statusCode}');
  } on DioException catch (e) {
    if (CancelToken.isCancel(e)) {
      print('cancelled: ${e.message}');
    } else {
      rethrow;
    }
  }
}
