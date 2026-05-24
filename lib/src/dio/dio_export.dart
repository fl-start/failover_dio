/// Platform-conditional export of [Dio] and [FailoverDio].
///
/// - On `dart.library.io` platforms (mobile, desktop, server, CLI):
///   loads [dio_io.dart] which extends `DioForNative` and installs the
///   failover adapter.
/// - On `dart.library.html` platforms (web): loads [dio_web.dart] which
///   delegates to stock Dio.
library;

export 'dio_io.dart' if (dart.library.html) 'dio_web.dart';
