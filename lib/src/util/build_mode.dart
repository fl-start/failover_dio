/// Compile-time build-mode constants and user opt-in flags.
///
/// Detection is done in pure Dart, with no Flutter dependency. The Dart VM
/// sets `dart.vm.product` to `true` for release builds and `dart.vm.profile`
/// to `true` for profile builds; everything else is debug.
library;

/// `true` when running in release/AOT mode (`dart compile exe`, `flutter run
/// --release`).
const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// `true` when running in profile mode (`flutter run --profile`).
const bool kProfileMode = bool.fromEnvironment('dart.vm.profile');

/// `true` when running in debug mode (JIT, no `--release`/`--profile`).
const bool kDebugMode = !kReleaseMode && !kProfileMode;

/// User opt-in via `--dart-define=FAILOVER_DIO_VERBOSE=true`.
///
/// Forces the console logger on even in release.
const bool kFailoverDioVerbose = bool.fromEnvironment(
  'FAILOVER_DIO_VERBOSE',
);

/// User opt-in via `--dart-define=FAILOVER_DIO_TIMELINE=true`.
///
/// Forces timeline events on even in release for production performance
/// audits.
const bool kFailoverDioTimeline = bool.fromEnvironment(
  'FAILOVER_DIO_TIMELINE',
);

/// `true` when the library should emit `dart:developer` Timeline events.
const bool kTimelineEnabled =
    kFailoverDioTimeline || kProfileMode || kDebugMode;

/// `true` when the library should emit one-time misconfiguration warnings on
/// `Dio` construction.
const bool kMisconfigWarningsEnabled = !kReleaseMode || kFailoverDioVerbose;
