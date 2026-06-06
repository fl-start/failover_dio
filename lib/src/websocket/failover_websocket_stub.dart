import '../cache/host_ip_cache.dart';
import '../config/failover_options.dart';
import '../observability/attempt_record.dart';

/// Web stub placeholder — WebSocket IP failover requires `dart:io`.
class FailoverWebSocket {
  FailoverWebSocket._();

  /// Not available on web.
  static Future<FailoverWebSocket> connect(
    String url, {
    FailoverOptions? failoverOptions,
    HostIpCache? cache,
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) {
    throw UnsupportedError(
      'FailoverWebSocket requires dart:io (mobile, desktop, server). '
      'On web, use package:web_socket_channel without IP failover.',
    );
  }

  /// Not available on web.
  dynamic get socket => throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  String get host => throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  String get winningIp => throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  String get idempotencyKey =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  List<AttemptRecord> get connectAttempts =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  Stream<dynamic> get stream =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  Future<void> send(dynamic data) =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  Future<void> reconnect() =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');

  /// Not available on web.
  Future<void> close([int? closeCode, String? closeReason]) =>
      throw UnsupportedError('FailoverWebSocket requires dart:io');
}
