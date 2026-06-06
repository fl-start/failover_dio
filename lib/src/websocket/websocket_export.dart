/// Platform-conditional export of [FailoverWebSocket].
///
/// - On `dart.library.io` platforms: full DNS-aware connect + reconnect.
/// - On web: [FailoverWebSocket.connect] throws [UnsupportedError].
library;

export 'failover_websocket_stub.dart'
    if (dart.library.io) 'failover_websocket_io.dart';
