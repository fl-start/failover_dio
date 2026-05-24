import 'dart:developer' as developer;

import '../observability/failover_logger.dart';

/// Default logger used in debug and profile builds when the user has not
/// supplied one.
///
/// Writes structured single-line entries via `dart:developer.log`, which is
/// visible in the DevTools Logging tab and surfaces in the IDE console.
class ConsoleFailoverLogger implements FailoverLogger {
  /// Creates a console logger with a minimum [minLevel]. Messages below
  /// [minLevel] are silently dropped.
  const ConsoleFailoverLogger({this.minLevel = FailoverLogLevel.debug});

  /// Minimum severity that will be emitted.
  final FailoverLogLevel minLevel;

  @override
  void log(FailoverLogLevel level, String message, {Object? fields}) {
    if (level.index < minLevel.index) return;
    final String tag = '[failover_dio:${level.name}]';
    final String fieldsStr = fields == null ? '' : ' $fields';
    developer.log('$tag $message$fieldsStr', name: 'failover_dio');
  }
}
