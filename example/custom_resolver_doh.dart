// Plug in a custom DnsResolver (DoH, gRPC, an in-house DNS service, etc.).
// v0.1 ships the abstract `DnsResolver`; users supply their own concrete
// implementation. Below is a sketch — replace with your real DoH client.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:failover_dio/failover_dio.dart';

class MyCustomResolver implements DnsResolver {
  @override
  Future<DnsAnswer> resolve(String host) async {
    // Replace with a real DoH HTTP call, custom DNS over TCP, etc. This
    // example simply delegates to the platform resolver and tags a fixed
    // TTL — but in practice you'd parse the upstream answer's TTL.
    final List<InternetAddress> addrs = await InternetAddress.lookup(host);
    return DnsAnswer(addresses: addrs, ttl: const Duration(seconds: 120));
  }
}

Future<void> main() async {
  final Dio dio = Dio(
    failoverOptions: FailoverOptions(dnsResolver: MyCustomResolver()),
  );

  final Response<dynamic> res = await dio.get<dynamic>('https://example.com/');
  print('status: ${res.statusCode}');
}
