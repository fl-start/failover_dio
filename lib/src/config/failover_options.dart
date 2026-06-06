import 'dart:math';

import '../body/body_replay_policy.dart';
import '../dns/dns_resolver.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../security/certificate_pinner.dart';
import '../util/build_mode.dart';
import '../util/clock.dart';
import '../util/console_failover_logger.dart';
import '../util/hostname_normalizer.dart';
import '../util/idempotency_key_generator.dart';
import 'host_override.dart';

/// Type-safe configuration for `FailoverDio`.
///
/// Every field has a sensible default; you only need to set what you want
/// to change. `copyWith` is provided for ergonomic overrides, and
/// [perHost] lets you override any field for specific hostnames.
class FailoverOptions {
  /// Creates options.
  FailoverOptions({
    this.getConnectTimeout = const Duration(seconds: 3),
    this.defaultConnectTimeout = const Duration(seconds: 8),
    this.overallTimeout = const Duration(seconds: 30),
    this.maxIpAttempts = 3,
    this.unavailableCooldownInitial = const Duration(seconds: 60),
    this.unavailableCooldownMax = const Duration(minutes: 15),
    this.unavailableCooldownFactor = 2.0,
    this.probeTimeout = const Duration(seconds: 2),
    this.dnsLookupTimeout = const Duration(seconds: 5),
    this.negativeCacheTtl = const Duration(seconds: 15),
    this.useSharedCache = true,
    this.maxCachedHosts = 256,
    this.enableLatencyProbe = true,
    this.probeFreshness = const Duration(seconds: 30),
    this.maxConcurrentProbes = 4,
    this.staleWhileRevalidate = true,
    this.maxStaleAge = const Duration(seconds: 60),
    this.enableFailoverHeaders = true,
    this.singleIpFastPath = true,
    this.latencyBucketMs = 10,
    this.redirectToPeerStatus,
    IdempotencyKeyGenerator? idempotencyKeyGenerator,
    BodyReplayPolicy? bodyReplay,
    DnsResolver? dnsResolver,
    this.requireDnssec = false,
    this.allowPrivateAddresses = true,
    this.dnsLocalHosts = const <String>{'localhost'},
    CertificatePinner? certificatePinner,
    this.onEvent,
    FailoverLogger? logger,
    this.debugSlowRequestThreshold = const Duration(seconds: 2),
    this.profileSlowRequestThreshold = const Duration(seconds: 5),
    bool? enableTimelineEvents,
    bool? enableMisconfigWarnings,
    this.perHost = const <String, HostOverride>{},
    Clock? clock,
    Random? random,
  })  : idempotencyKeyGenerator = idempotencyKeyGenerator ??
            SecureRandomIdempotencyKeyGenerator(),
        bodyReplay = bodyReplay ?? const BodyReplayPolicy.bufferUpTo(1024 * 1024),
        dnsResolver = dnsResolver ?? const PlatformDnsResolver(),
        certificatePinner = certificatePinner ?? CertificatePinner.empty(),
        logger = logger ?? _defaultLogger(),
        enableTimelineEvents = enableTimelineEvents ?? kTimelineEnabled,
        enableMisconfigWarnings =
            enableMisconfigWarnings ?? kMisconfigWarningsEnabled,
        clock = clock ?? const SystemClock(),
        random = random ?? Random.secure();

  // ===== Timeouts and attempts =====

  /// Fail-over trigger for GET/HEAD (default 3s).
  final Duration getConnectTimeout;

  /// Fail-over trigger for POST/PUT/PATCH/DELETE (default 8s).
  final Duration defaultConnectTimeout;

  /// Hard ceiling for the whole logical request (default 30s).
  final Duration overallTimeout;

  /// Parallel TCP connect fan-out per Happy Eyeballs wave (default 3).
  ///
  /// On each wave, up to this many gateway IPs receive concurrent
  /// `Socket.startConnect` calls; the first SYN+ACK wins and receives the
  /// single HTTP exchange. If the wave produces no winner, the next wave
  /// takes the next slice of resolved addresses until one succeeds or the
  /// DNS roster is exhausted.
  final int maxIpAttempts;

  /// Initial cooldown when marking an IP unavailable (default 60s).
  final Duration unavailableCooldownInitial;

  /// Maximum cooldown after repeated failures (default 15m).
  final Duration unavailableCooldownMax;

  /// Cooldown multiplier per consecutive failure (default 2.0).
  final double unavailableCooldownFactor;

  /// Per-IP TCP connect timeout inside a Happy Eyeballs wave (default 2s).
  final Duration probeTimeout;

  /// Per-host DNS lookup timeout (default 5s).
  final Duration dnsLookupTimeout;

  /// Negative cache TTL for failed lookups (default 15s).
  final Duration negativeCacheTtl;

  // ===== Cache and probing =====

  /// Use the process-wide shared cache (default `true`).
  final bool useSharedCache;

  /// Maximum hosts before LRU eviction (default 256).
  final int maxCachedHosts;

  /// Run parallel TCP Happy Eyeballs connect races on each request wave
  /// (default `true`). When `false`, each wave issues HTTP to the first
  /// DNS-ordered IP without a connect race (warmup still uses probes).
  final bool enableLatencyProbe;

  /// Minimum interval between probes for the same IP (default 30s).
  final Duration probeFreshness;

  /// Reserved for future cross-host probe budgeting. Within a single host,
  /// Happy Eyeballs races **all** eligible IPs in parallel regardless of
  /// this value.
  final int maxConcurrentProbes;

  /// Serve stale cache entries while refreshing (default `true`).
  final bool staleWhileRevalidate;

  /// Max age a stale entry can be served past TTL (default 60s).
  final Duration maxStaleAge;

  // ===== Headers and idempotency =====

  /// Whether to inject `failover_dio_*` headers (default `true`).
  final bool enableFailoverHeaders;

  /// When DNS resolves to **exactly one** usable IP for a host, route the
  /// request through the standard `IOHttpClientAdapter` with **identical
  /// wire behavior to stock Dio**: no request body buffering, no
  /// `failover_dio_*` headers, no `FailoverEvent`s, no `Response.extra`
  /// metadata, and no per-IP pinned `HttpClient`.
  ///
  /// Set to `false` if you want the full failover instrumentation
  /// (observability metadata, idempotency key, events) on every request
  /// regardless of IP cardinality — typically for unified server-side
  /// metrics or strict idempotency guarantees.
  ///
  /// Defaults to `true`.
  final bool singleIpFastPath;

  /// Latency quantisation bucket in milliseconds (default 10).
  ///
  /// IPs whose measured latency falls in the same bucket (i.e.
  /// `latencyMs ~/ latencyBucketMs` is equal) are considered equivalent
  /// and randomly shuffled. This prevents microvariance (e.g. 12 ms vs
  /// 14 ms) from causing constant ranking churn, and distributes load
  /// across statistically equivalent gateways.
  ///
  /// Set to `1` to disable bucketing and use exact millisecond values.
  final int latencyBucketMs;

  /// HTTP status code emitted by a gateway to signal "try another peer"
  /// (default `null` — only transport failures trigger fail-over).
  ///
  /// When `null` (the default), **every** HTTP response — including any
  /// 4xx or 5xx — is returned to the caller immediately without retrying a
  /// different IP. This is the correct default for standard deployments: HTTP
  /// error codes represent application-layer decisions that the gateway made
  /// deliberately, not transport failures.
  ///
  /// Set this to a specific status code that your API-gateway infrastructure
  /// uses to signal "this instance cannot serve the request, try a peer". A
  /// common convention is **553** (outside the IANA-assigned 5xx range, so
  /// it cannot be confused with standard server errors):
  ///
  /// ```dart
  /// FailoverOptions(redirectToPeerStatus: 553)
  /// ```
  ///
  /// When a response with this exact status code is received:
  /// - The IP is placed in a short transient cooldown
  ///   (`unavailableCooldownInitial / 2`) without incrementing the
  ///   consecutive-failure counter.
  /// - The next ranked IP is attempted.
  /// - Fail-over is only applied when the request body can be replayed.
  ///   Non-replayable stream bodies will still return the response
  ///   immediately.
  ///
  /// All other HTTP responses (1xx–4xx and remaining 5xx) are returned to
  /// the caller without any retry.
  final int? redirectToPeerStatus;

  /// Source of per-request idempotency keys.
  final IdempotencyKeyGenerator idempotencyKeyGenerator;

  // ===== Body replay =====

  /// Policy for non-replayable bodies (default `bufferUpTo(1MB)`).
  final BodyReplayPolicy bodyReplay;

  // ===== DNS =====

  /// DNS resolver implementation (default [PlatformDnsResolver]).
  final DnsResolver dnsResolver;

  /// Require DNSSEC validation (default `false`; not yet enforced).
  final bool requireDnssec;

  /// Allow private/RFC1918 addresses for public hosts (default `true`).
  final bool allowPrivateAddresses;

  /// Hosts (normalized) for which any resolved address — including loopback,
  /// private, and link-local — is permitted regardless of
  /// [allowPrivateAddresses]. Defaults to `{'localhost'}`. Any host ending
  /// in `.local` is also always considered local.
  final Set<String> dnsLocalHosts;

  // ===== Security =====

  /// Certificate pin configuration (no enforcement in v0.1).
  final CertificatePinner certificatePinner;

  // ===== Observability =====

  /// Per-event callback invoked synchronously on emission.
  final void Function(FailoverEvent)? onEvent;

  /// Pluggable logger.
  final FailoverLogger logger;

  /// Threshold above which a request is logged as slow in debug mode.
  final Duration debugSlowRequestThreshold;

  /// Threshold above which a request is logged as slow in profile mode.
  final Duration profileSlowRequestThreshold;

  /// Whether to wrap operations in `dart:developer.Timeline` calls.
  final bool enableTimelineEvents;

  /// Whether to log misconfiguration warnings at construction.
  final bool enableMisconfigWarnings;

  // ===== Per-host overrides =====

  /// Per-host overlays; keys are normalized hostnames.
  final Map<String, HostOverride> perHost;

  // ===== Extension points =====

  /// Pluggable wall-clock source.
  final Clock clock;

  /// Pluggable random source for idempotency and probe jitter.
  final Random random;

  /// Looks up the override for [host] (case-insensitive, trailing-dot
  /// safe). Returns `null` if no override exists.
  HostOverride? overrideFor(String host) {
    if (perHost.isEmpty) return null;
    final String h = HostnameNormalizer.normalize(host);
    return perHost[h];
  }

  /// Returns the effective GET connect timeout for [host].
  Duration getConnectTimeoutFor(String host) =>
      overrideFor(host)?.getConnectTimeout ?? getConnectTimeout;

  /// Returns the effective default connect timeout for [host].
  Duration defaultConnectTimeoutFor(String host) =>
      overrideFor(host)?.defaultConnectTimeout ?? defaultConnectTimeout;

  /// Returns the effective overall timeout for [host].
  Duration overallTimeoutFor(String host) =>
      overrideFor(host)?.overallTimeout ?? overallTimeout;

  /// Returns the effective `maxIpAttempts` for [host].
  int maxIpAttemptsFor(String host) =>
      overrideFor(host)?.maxIpAttempts ?? maxIpAttempts;

  /// Returns the effective probe-enabled flag for [host].
  bool enableLatencyProbeFor(String host) =>
      overrideFor(host)?.enableLatencyProbe ?? enableLatencyProbe;

  /// Returns the effective `allowPrivateAddresses` for [host].
  bool allowPrivateAddressesFor(String host) =>
      overrideFor(host)?.allowPrivateAddresses ?? allowPrivateAddresses;

  /// Returns the effective `enableFailoverHeaders` for [host].
  bool enableFailoverHeadersFor(String host) =>
      overrideFor(host)?.enableFailoverHeaders ?? enableFailoverHeaders;

  /// Returns the effective `singleIpFastPath` for [host].
  bool singleIpFastPathFor(String host) =>
      overrideFor(host)?.singleIpFastPath ?? singleIpFastPath;

  /// Returns the effective `latencyBucketMs` for [host].
  int latencyBucketMsFor(String host) =>
      overrideFor(host)?.latencyBucketMs ?? latencyBucketMs;

  /// Returns the effective `redirectToPeerStatus` for [host].
  int? redirectToPeerStatusFor(String host) =>
      overrideFor(host)?.redirectToPeerStatus ?? redirectToPeerStatus;

  /// Returns a copy with the given fields overridden.
  FailoverOptions copyWith({
    Duration? getConnectTimeout,
    Duration? defaultConnectTimeout,
    Duration? overallTimeout,
    int? maxIpAttempts,
    Duration? unavailableCooldownInitial,
    Duration? unavailableCooldownMax,
    double? unavailableCooldownFactor,
    Duration? probeTimeout,
    Duration? dnsLookupTimeout,
    Duration? negativeCacheTtl,
    bool? useSharedCache,
    int? maxCachedHosts,
    bool? enableLatencyProbe,
    Duration? probeFreshness,
    int? maxConcurrentProbes,
    bool? staleWhileRevalidate,
    Duration? maxStaleAge,
    bool? enableFailoverHeaders,
    bool? singleIpFastPath,
    int? latencyBucketMs,
    // Use _Unset sentinel so callers can explicitly pass null to clear the
    // redirectToPeerStatus (setting int? via ?? would be ambiguous).
    Object? redirectToPeerStatus = const _Unset(),
    IdempotencyKeyGenerator? idempotencyKeyGenerator,
    BodyReplayPolicy? bodyReplay,
    DnsResolver? dnsResolver,
    bool? requireDnssec,
    bool? allowPrivateAddresses,
    Set<String>? dnsLocalHosts,
    CertificatePinner? certificatePinner,
    void Function(FailoverEvent)? onEvent,
    FailoverLogger? logger,
    Duration? debugSlowRequestThreshold,
    Duration? profileSlowRequestThreshold,
    bool? enableTimelineEvents,
    bool? enableMisconfigWarnings,
    Map<String, HostOverride>? perHost,
    Clock? clock,
    Random? random,
  }) {
    return FailoverOptions(
      getConnectTimeout: getConnectTimeout ?? this.getConnectTimeout,
      defaultConnectTimeout:
          defaultConnectTimeout ?? this.defaultConnectTimeout,
      overallTimeout: overallTimeout ?? this.overallTimeout,
      maxIpAttempts: maxIpAttempts ?? this.maxIpAttempts,
      unavailableCooldownInitial:
          unavailableCooldownInitial ?? this.unavailableCooldownInitial,
      unavailableCooldownMax:
          unavailableCooldownMax ?? this.unavailableCooldownMax,
      unavailableCooldownFactor:
          unavailableCooldownFactor ?? this.unavailableCooldownFactor,
      probeTimeout: probeTimeout ?? this.probeTimeout,
      dnsLookupTimeout: dnsLookupTimeout ?? this.dnsLookupTimeout,
      negativeCacheTtl: negativeCacheTtl ?? this.negativeCacheTtl,
      useSharedCache: useSharedCache ?? this.useSharedCache,
      maxCachedHosts: maxCachedHosts ?? this.maxCachedHosts,
      enableLatencyProbe: enableLatencyProbe ?? this.enableLatencyProbe,
      probeFreshness: probeFreshness ?? this.probeFreshness,
      maxConcurrentProbes: maxConcurrentProbes ?? this.maxConcurrentProbes,
      staleWhileRevalidate: staleWhileRevalidate ?? this.staleWhileRevalidate,
      maxStaleAge: maxStaleAge ?? this.maxStaleAge,
      enableFailoverHeaders:
          enableFailoverHeaders ?? this.enableFailoverHeaders,
      singleIpFastPath: singleIpFastPath ?? this.singleIpFastPath,
      latencyBucketMs: latencyBucketMs ?? this.latencyBucketMs,
      redirectToPeerStatus: redirectToPeerStatus is _Unset
          ? this.redirectToPeerStatus
          : redirectToPeerStatus as int?,
      idempotencyKeyGenerator:
          idempotencyKeyGenerator ?? this.idempotencyKeyGenerator,
      bodyReplay: bodyReplay ?? this.bodyReplay,
      dnsResolver: dnsResolver ?? this.dnsResolver,
      requireDnssec: requireDnssec ?? this.requireDnssec,
      allowPrivateAddresses:
          allowPrivateAddresses ?? this.allowPrivateAddresses,
      dnsLocalHosts: dnsLocalHosts ?? this.dnsLocalHosts,
      certificatePinner: certificatePinner ?? this.certificatePinner,
      onEvent: onEvent ?? this.onEvent,
      logger: logger ?? this.logger,
      debugSlowRequestThreshold:
          debugSlowRequestThreshold ?? this.debugSlowRequestThreshold,
      profileSlowRequestThreshold:
          profileSlowRequestThreshold ?? this.profileSlowRequestThreshold,
      enableTimelineEvents:
          enableTimelineEvents ?? this.enableTimelineEvents,
      enableMisconfigWarnings:
          enableMisconfigWarnings ?? this.enableMisconfigWarnings,
      perHost: perHost ?? this.perHost,
      clock: clock ?? this.clock,
      random: random ?? this.random,
    );
  }

  static FailoverLogger _defaultLogger() {
    if (kReleaseMode && !kFailoverDioVerbose) {
      return const NoOpFailoverLogger();
    }
    if (kDebugMode) {
      return const ConsoleFailoverLogger(minLevel: FailoverLogLevel.debug);
    }
    return const ConsoleFailoverLogger(minLevel: FailoverLogLevel.warn);
  }
}

/// Private sentinel used by [FailoverOptions.copyWith] to distinguish between
/// "caller did not pass redirectToPeerStatus" and "caller explicitly passed
/// null" (which clears a previously set code).
class _Unset {
  const _Unset();
}
