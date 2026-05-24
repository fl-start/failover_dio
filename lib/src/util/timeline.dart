import 'dart:developer' as developer;

import 'build_mode.dart';

/// Lightweight wrapper around `dart:developer` Timeline that no-ops in release.
///
/// Usage:
/// ```dart
/// FailoverTimeline.sync('resolve_host', () => doResolution());
/// final flow = FailoverTimeline.startFlow('attempt:$host:$ip');
/// // ... async work ...
/// FailoverTimeline.finishFlow(flow);
/// ```
class FailoverTimeline {
  FailoverTimeline._();

  /// Synchronous timeline span. Stripped in release mode unless the user
  /// passed `--dart-define=FAILOVER_DIO_TIMELINE=true`.
  static T sync<T>(String name, T Function() body, {Map<String, Object?>? args}) {
    if (!kTimelineEnabled) {
      return body();
    }
    return developer.Timeline.timeSync<T>(
      'failover_dio:$name',
      body,
      arguments: args,
    );
  }

  /// Starts an async flow. Returns the flow handle, or `null` if timeline is
  /// disabled. Pair with [finishFlow].
  static developer.Flow? startFlow(String name) {
    if (!kTimelineEnabled) return null;
    final developer.Flow f = developer.Flow.begin();
    developer.Timeline.startSync('failover_dio:$name', flow: f);
    developer.Timeline.finishSync();
    return f;
  }

  /// Finishes an async flow started by [startFlow]. No-op if [flow] is null.
  static void finishFlow(developer.Flow? flow) {
    if (flow == null || !kTimelineEnabled) return;
    final developer.Flow end = developer.Flow.end(flow.id);
    developer.Timeline.startSync('failover_dio:flow_end', flow: end);
    developer.Timeline.finishSync();
  }
}
