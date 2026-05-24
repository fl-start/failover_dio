// Different services often have different SLAs. Per-host overrides let you
// tighten timeouts for internal hosts while keeping defaults for the rest.

// ignore_for_file: avoid_print

import 'package:failover_dio/failover_dio.dart';

Future<void> main() async {
  final Dio dio = Dio(
    failoverOptions: FailoverOptions(
      defaultConnectTimeout: const Duration(seconds: 8),
      maxIpAttempts: 3,
      perHost: const <String, HostOverride>{
        'api.internal.example.com': HostOverride(
          getConnectTimeout: Duration(seconds: 1),
          maxIpAttempts: 5,
          allowPrivateAddresses: true,
        ),
        'cdn.example.com': HostOverride(enableLatencyProbe: false),
      },
    ),
  );

  await dio.get<dynamic>('https://api.internal.example.com/health');
  await dio.get<dynamic>('https://cdn.example.com/asset.png');
}
