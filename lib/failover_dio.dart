/// `failover_dio` — a drop-in `dio` replacement with DNS-aware IP failover,
/// staggered in-flight retries, latency-based routing, TTL-driven cache
/// refresh, and observability headers.
///
/// **Migration**: change
/// ```dart
/// import 'package:dio/dio.dart';
/// ```
/// to
/// ```dart
/// import 'package:failover_dio/failover_dio.dart';
/// ```
/// No other code changes required. Everything Dio exports (interceptors,
/// `CancelToken`, `BaseOptions`, `Response`, exceptions, etc.) is
/// re-exported here so existing call-sites keep working.
library;

// Re-export the entire Dio surface except for `Dio` itself, which is
// replaced by our platform-conditional class.
export 'package:dio/dio.dart' hide Dio;

// Platform-conditional Dio / FailoverDio implementation.
export 'src/dio/dio_export.dart';

// Public configuration and types users will reach for.
export 'src/adapter/failover_http_client_adapter.dart' show FailoverHttpClientAdapter;
export 'src/body/body_replay_policy.dart';
export 'src/cache/host_ip_cache.dart' show HostIpCache, HostCacheRow;
export 'src/cache/ip_entry.dart';
export 'src/config/failover_headers.dart';
export 'src/config/failover_options.dart';
export 'src/config/host_override.dart';
export 'src/dns/dns_resolver.dart';
export 'src/dns/doh_resolver.dart';
export 'src/errors/failover_exhausted_error.dart';
export 'src/latency/latency_probe.dart';
export 'src/latency/tcp_connect_probe.dart';
export 'src/observability/attempt_record.dart';
export 'src/observability/cache_inspector.dart';
export 'src/observability/failover_event.dart';
export 'src/observability/failover_logger.dart';
export 'src/security/certificate_pinner.dart';
export 'src/util/address_validator.dart';
export 'src/util/build_mode.dart';
export 'src/util/clock.dart';
export 'src/util/console_failover_logger.dart';
export 'src/util/hostname_normalizer.dart';
export 'src/util/idempotency_key_generator.dart';
export 'src/util/metrics.dart';
