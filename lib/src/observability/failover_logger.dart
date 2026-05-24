/// Severity levels for [FailoverLogger].
enum FailoverLogLevel {
  /// Most verbose; per-step trace.
  trace,

  /// Debug-level information.
  debug,

  /// Informational milestones (resolved, attempt succeeded).
  info,

  /// Recoverable problems (attempt failed, IP marked unavailable).
  warn,

  /// Unrecoverable problems (request exhausted, configuration error).
  error,
}

/// Pluggable logger interface.
///
/// Defaults to [NoOpFailoverLogger] in release builds (zero log noise) and
/// can be replaced by users with adapters for `package:logging`,
/// `dart:developer.log`, Sentry breadcrumbs, etc.
abstract class FailoverLogger {
  /// Emits a log line at [level].
  void log(FailoverLogLevel level, String message, {Object? fields});
}

/// No-op logger; the default in release mode.
class NoOpFailoverLogger implements FailoverLogger {
  /// Creates the const no-op logger.
  const NoOpFailoverLogger();

  @override
  void log(FailoverLogLevel level, String message, {Object? fields}) {}
}
