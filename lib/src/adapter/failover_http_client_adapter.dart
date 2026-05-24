import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../body/body_replay_policy.dart';
import '../cache/host_ip_cache.dart';
import '../cache/ip_entry.dart';
import '../config/failover_headers.dart';
import '../config/failover_options.dart';
import '../errors/failover_exhausted_error.dart';
import '../latency/latency_probe.dart';
import '../latency/probe_scheduler.dart';
import '../latency/tcp_connect_probe.dart';
import '../observability/attempt_record.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../util/build_mode.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import '../util/timeline.dart';

/// `HttpClientAdapter` that adds DNS-aware IP failover, staggered in-flight
/// retries, idempotency/observability headers, and CancelToken-aware
/// orchestration on top of Dio's standard transport.
///
/// Constructed once per `Dio` instance via the failover `Dio` subclass.
class FailoverHttpClientAdapter implements HttpClientAdapter {
  /// Creates an adapter.
  FailoverHttpClientAdapter({
    FailoverOptions? options,
    HostIpCache? cache,
    LatencyProbe? probe,
  })  : _options = options ?? FailoverOptions(),
        _maxPinned = (options ?? FailoverOptions()).maxCachedHosts {
    final bool useShared = cache == null && _options.useSharedCache;
    _cache = cache ??
        (useShared
            ? HostIpCache.sharedWithDefaults(_options)
            : HostIpCache(
                resolver: _options.dnsResolver,
                options: _options,
                clock: _options.clock,
                logger: _options.logger,
                onEvent: _options.onEvent,
              ));
    if (useShared && _options.onEvent != null) {
      _sharedListenerRemover =
          HostIpCache.addSharedListener(_options.onEvent!);
    }
    _probeScheduler = ProbeScheduler(
      probe: probe ?? TcpConnectProbe(defaultTimeout: _options.probeTimeout),
      cache: _cache,
      options: _options,
      clock: _options.clock,
      logger: _options.logger,
      onEvent: _options.onEvent,
    );
    _logMisconfigWarnings();
  }

  /// Removes the shared-cache listener registration on close (if any).
  void Function()? _sharedListenerRemover;

  final FailoverOptions _options;
  late final HostIpCache _cache;
  late final ProbeScheduler _probeScheduler;
  final int _maxPinned;

  /// Cache of pinned `IOHttpClientAdapter`s, one per `(normalizedHost, ip)`.
  final LinkedHashMap<String, IOHttpClientAdapter> _pinned =
      LinkedHashMap<String, IOHttpClientAdapter>();

  /// Fallback adapter for bypass paths (IP literals, localhost, .local,
  /// or `extra['failover_dio:skip']`).
  late final IOHttpClientAdapter _passthrough = IOHttpClientAdapter();

  // SingleFlight is exported for future use (cold-start coalescing beyond
  // the HttpClient pool); see [SingleFlight] in this library.

  bool _closed = false;
  bool _misconfigLogged = false;

  /// Access to the underlying cache (used by `FailoverDio` static helpers).
  HostIpCache get cache => _cache;

  /// Access to the probe scheduler (used by warmup).
  ProbeScheduler get probeScheduler => _probeScheduler;

  /// Effective options.
  FailoverOptions get options => _options;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      throw StateError('FailoverHttpClientAdapter has been closed');
    }
    FailoverMetrics.instance.incRequests();

    if (_shouldBypass(options)) {
      return _passthrough.fetch(options, requestStream, cancelFuture);
    }

    final String host = HostnameNormalizer.normalize(options.uri.host);

    // Resolve host (DNS + cache). We do this BEFORE buffering the body so
    // the single-IP fast path can stream the body directly to the
    // standard adapter without ever touching it (zero extra memory, zero
    // wire-level deviation from stock Dio).
    final List<IpEntry> entries;
    try {
      entries = await FailoverTimeline.sync(
        'resolve_host',
        () => _cache.resolveIfNeeded(host),
        args: <String, Object?>{'host': host},
      );
    } catch (e, s) {
      throw DioException(
        requestOptions: options,
        error: e,
        stackTrace: s,
        type: DioExceptionType.connectionError,
        message: 'DNS resolution for $host failed: $e',
      );
    }

    if (entries.isEmpty) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'DNS resolution for $host returned no usable addresses',
      );
    }

    // Single-IP fast path: there is nothing to fail over TO, so issue
    // the request directly against the pinned adapter for that one IP
    // and skip every piece of failover instrumentation.
    //
    // Specifically, compared to stock Dio:
    //   - the request body is **not** buffered (streamed straight through)
    //   - **no** `failover_dio_*` headers are injected
    //   - **no** `FailoverEvent`s are emitted
    //   - **no** `Response.extra` metadata is written
    //   - **no** per-request Stopwatch/Completer/Timer is allocated
    //
    // Net cost vs stock Dio: one O(1) cache lookup (or one identical-
    // cost OS DNS lookup on cold cache) plus a long-lived per-`(host,ip)`
    // `HttpClient` (reused across requests). The server sees a wire
    // request indistinguishable from the one stock Dio would have sent.
    if (entries.length == 1 && _options.singleIpFastPathFor(host)) {
      final IpEntry only = entries.first;
      final IOHttpClientAdapter adapter =
          _pinnedAdapterFor(host, only.address);
      return adapter.fetch(options, requestStream, cancelFuture);
    }

    final int port = options.uri.hasPort
        ? options.uri.port
        : (options.uri.scheme == 'https' ? 443 : 80);

    // Buffer body once for cross-attempt replay (multi-IP path only).
    final _BufferedBody bodyResult =
        await _bufferBody(requestStream, options.method);
    final Uint8List? bodyBytes = bodyResult.bytes;
    final bool singleAttemptOnly = bodyResult.singleAttempt;

    // Trigger background probes (only when more than one IP is known).
    if (_options.enableLatencyProbeFor(host)) {
      _probeScheduler.maybeProbeAll(host, port: port);
    }

    final int maxAttempts =
        _resolveMaxIpAttempts(options, host, singleAttemptOnly);
    final List<IpEntry> ordered = _cache.orderedEntries(host);
    final List<IpEntry> candidates =
        ordered.take(maxAttempts).toList(growable: false);
    if (candidates.isEmpty) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'No candidate IPs available for $host',
      );
    }

    return _runCoordinator(
      requestOptions: options,
      candidates: candidates,
      bodyBytes: bodyBytes,
      cancelFuture: cancelFuture,
      host: host,
      port: port,
      maxAttempts: maxAttempts,
    );
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _sharedListenerRemover?.call();
    _sharedListenerRemover = null;
    for (final IOHttpClientAdapter a in _pinned.values) {
      a.close(force: force);
    }
    _pinned.clear();
    _passthrough.close(force: force);
  }

  // ============== Implementation details ==============

  bool _shouldBypass(RequestOptions options) {
    if (options.extra[FailoverExtraKeys.skip] == true) return true;
    final String host = options.uri.host;
    if (host.isEmpty) return true;
    // IPv4/IPv6 literals.
    if (_isIpLiteral(host)) return true;
    final String norm = HostnameNormalizer.normalize(host);
    if (norm == 'localhost') return true;
    if (norm.endsWith('.local')) return true;
    // v0.1 limitation: HTTPS pinning requires a SecureSocket-yielding
    // ConnectionTask which dart:io's connectionFactory API cannot
    // produce (final ConnectionTask + invariant generics). HTTPS hosts
    // fall back to the standard adapter (no per-IP failover) until v0.2
    // ships a custom HTTP/1.1 transport.
    if (options.uri.scheme == 'https') return true;
    return false;
  }

  bool _isIpLiteral(String host) {
    if (host.startsWith('[') && host.endsWith(']')) return true;
    try {
      InternetAddress(host);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  Future<_BufferedBody> _bufferBody(
    Stream<Uint8List>? stream,
    String method,
  ) async {
    if (stream == null) {
      return const _BufferedBody(bytes: null, singleAttempt: false);
    }
    final BodyReplayPolicy policy = _options.bodyReplay;
    final BytesBuilder buffer = BytesBuilder(copy: false);
    int total = 0;
    int? maxBytes;
    if (policy.mode == BodyReplayMode.bufferUpTo) {
      maxBytes = policy.maxBufferBytes;
    }
    try {
      await for (final Uint8List chunk in stream) {
        total += chunk.length;
        if (maxBytes != null && total > maxBytes) {
          switch (policy.mode) {
            case BodyReplayMode.bufferUpTo:
              return _BufferedBody(
                bytes: _concat(buffer, chunk),
                singleAttempt: true,
              );
            case BodyReplayMode.refuse:
              throw StateError(
                'failover_dio: request body exceeds bodyReplay limit '
                'of ${policy.maxBufferBytes} bytes and policy is refuse()',
              );
            case BodyReplayMode.noFailover:
              return _BufferedBody(
                bytes: _concat(buffer, chunk),
                singleAttempt: true,
              );
          }
        }
        buffer.add(chunk);
      }
    } on StateError {
      rethrow;
    }
    final Uint8List bytes = buffer.toBytes();
    return _BufferedBody(bytes: bytes, singleAttempt: false);
  }

  Uint8List _concat(BytesBuilder buffer, Uint8List chunk) {
    buffer.add(chunk);
    return buffer.toBytes();
  }

  int _resolveMaxIpAttempts(
    RequestOptions options,
    String host,
    bool singleAttemptOnly,
  ) {
    if (singleAttemptOnly) return 1;
    final Object? perReq = options.extra[FailoverExtraKeys.maxIpAttempts];
    if (perReq is int && perReq > 0) return perReq;
    return _options.maxIpAttemptsFor(host);
  }

  Duration _methodFailoverTimeout(RequestOptions options, String host) {
    // Per-request override via Dio's Options.connectTimeout wins.
    final Duration? perReq = options.connectTimeout;
    if (perReq != null) return perReq;
    final String m = options.method.toUpperCase();
    if (m == 'GET' || m == 'HEAD') {
      return _options.getConnectTimeoutFor(host);
    }
    return _options.defaultConnectTimeoutFor(host);
  }

  Duration _overallDeadline(RequestOptions options, String host) {
    final Object? perReq = options.extra[FailoverExtraKeys.overallTimeout];
    if (perReq is Duration) return perReq;
    return _options.overallTimeoutFor(host);
  }

  IOHttpClientAdapter _pinnedAdapterFor(String host, InternetAddress ip) {
    final String key = '$host|${ip.address}|${ip.type.name}';
    final IOHttpClientAdapter? existing = _pinned.remove(key);
    if (existing != null) {
      _pinned[key] = existing;
      return existing;
    }
    final IOHttpClientAdapter created = IOHttpClientAdapter(
      createHttpClient: () {
        final HttpClient client = HttpClient()
          ..connectionFactory =
              (Uri uri, String? proxyHost, int? proxyPort) {
            // dart:io's HttpClient does NOT auto-upgrade the socket
            // returned by connectionFactory for HTTPS, and
            // ConnectionTask is a `final` class so we cannot wrap a
            // SecureSocket-yielding task in a ConnectionTask<Socket>.
            // HTTPS failover therefore requires a custom HTTP/1.1
            // transport (v0.2). HTTPS requests are routed via the
            // passthrough adapter in fetch(); this factory only ever
            // sees HTTP requests for pinned IPs.
            return Socket.startConnect(ip, uri.port);
          };
        return client;
      },
    );
    _pinned[key] = created;
    while (_pinned.length > _maxPinned) {
      final String victim = _pinned.keys.first;
      final IOHttpClientAdapter dead = _pinned.remove(victim)!;
      dead.close(force: false);
    }
    return created;
  }

  void _emit(FailoverEvent e) {
    try {
      _options.onEvent?.call(e);
    } catch (_) {
      // never let listeners crash the adapter
    }
  }

  Future<ResponseBody> _runCoordinator({
    required RequestOptions requestOptions,
    required List<IpEntry> candidates,
    required Uint8List? bodyBytes,
    required Future<void>? cancelFuture,
    required String host,
    required int port,
    required int maxAttempts,
  }) async {
    final String idempotencyKey =
        _options.idempotencyKeyGenerator.generate();
    final Stopwatch overall = Stopwatch()..start();
    final List<AttemptRecord> records = <AttemptRecord>[];
    final Completer<ResponseBody> winner = Completer<ResponseBody>();
    final List<_AttemptState> attempts = <_AttemptState>[];
    int nextIndex = 0;
    String? lastTriedIp;

    Timer? failoverTimer;
    Timer? overallTimer;
    StreamSubscription<void>? cancelSub;

    void cancelTimers() {
      failoverTimer?.cancel();
      failoverTimer = null;
      overallTimer?.cancel();
      overallTimer = null;
    }

    Future<void> abortAll(AttemptOutcome reason) async {
      for (final _AttemptState a in attempts) {
        if (!a.aborted && !a.completed) {
          a.aborted = true;
          if (!a.abortCompleter.isCompleted) {
            a.abortCompleter.complete();
          }
          _emit(AttemptAborted(
            host: host,
            ip: a.ip.addressString,
            attemptIndex: a.index,
            reason: reason,
          ));
        }
      }
    }

    void startNextAttempt() {
      if (winner.isCompleted) return;
      if (nextIndex >= candidates.length) return;
      final IpEntry ip = candidates[nextIndex];
      final int idx = nextIndex;
      nextIndex++;

      if (idx > 0) FailoverMetrics.instance.incFailovers();

      final _AttemptState state = _AttemptState(idx, ip);
      attempts.add(state);

      final String? prevIp = lastTriedIp;
      lastTriedIp = ip.addressString;

      _emit(AttemptStarted(
        host: host,
        ip: ip.addressString,
        attemptIndex: idx,
        idempotencyKey: idempotencyKey,
        previousIp: prevIp,
      ));
      _options.logger.log(FailoverLogLevel.debug, 'attempt_started',
          fields: <String, Object?>{
            'host': host,
            'ip': ip.addressString,
            'attempt': idx,
            'idem': idempotencyKey,
            if (prevIp != null) 'previousIp': prevIp,
          });

      final RequestOptions cloned = _cloneWithHeaders(
        requestOptions,
        idempotencyKey: idempotencyKey,
        previousIp: prevIp,
        host: host,
      );
      final Stream<Uint8List>? freshBody = bodyBytes == null
          ? null
          : Stream<Uint8List>.fromIterable(<Uint8List>[bodyBytes]);
      final IOHttpClientAdapter adapter = _pinnedAdapterFor(host, ip.address);
      // HttpClient connection pooling already coalesces concurrent attempts
      // to the same (host, ip); singleflight is reserved for future use.
      final Future<ResponseBody> attemptFuture =
          adapter.fetch(cloned, freshBody, state.abortCompleter.future);

      attemptFuture.then((ResponseBody body) {
        state.completed = true;
        state.sw.stop();
        if (winner.isCompleted) {
          // Stale; record as aborted-by-winner and tear down.
          records.add(AttemptRecord(
            attemptIndex: idx,
            ip: ip.addressString,
            outcome: AttemptOutcome.abortedByWinner,
            durationMs: state.sw.elapsedMilliseconds,
            statusCode: body.statusCode,
          ));
          if (!state.abortCompleter.isCompleted) state.abortCompleter.complete();
          return;
        }
        records.add(AttemptRecord(
          attemptIndex: idx,
          ip: ip.addressString,
          outcome: AttemptOutcome.succeeded,
          durationMs: state.sw.elapsedMilliseconds,
          statusCode: body.statusCode,
        ));
        _emit(AttemptSucceeded(
          host: host,
          ip: ip.addressString,
          attemptIndex: idx,
          statusCode: body.statusCode,
          durationMs: state.sw.elapsedMilliseconds,
        ));
        _options.logger.log(FailoverLogLevel.info, 'attempt_succeeded',
            fields: <String, Object?>{
              'host': host,
              'ip': ip.addressString,
              'attempt': idx,
              'status': body.statusCode,
              'ms': state.sw.elapsedMilliseconds,
            });
        _cache.markAvailable(host, ip.address);

        overall.stop();
        // Synthesize aborted-by-winner records for any in-flight loser
        // so the response carries a complete attempt picture.
        for (final _AttemptState a in attempts) {
          if (a.index == idx) continue;
          if (a.completed || a.aborted) continue;
          records.add(AttemptRecord(
            attemptIndex: a.index,
            ip: a.ip.addressString,
            outcome: AttemptOutcome.abortedByWinner,
            durationMs: a.sw.elapsedMilliseconds,
          ));
        }
        final List<AttemptRecord> sortedRecords =
            List<AttemptRecord>.of(records)
              ..sort((AttemptRecord a, AttemptRecord b) =>
                  a.attemptIndex.compareTo(b.attemptIndex));
        _annotateResponse(
          body,
          host: host,
          ip: ip.addressString,
          attempts: List<AttemptRecord>.unmodifiable(sortedRecords),
          idempotencyKey: idempotencyKey,
          totalMs: overall.elapsedMilliseconds,
        );
        winner.complete(body);
        cancelTimers();
        // Fire-and-forget abort of other attempts.
        unawaited(abortAll(AttemptOutcome.abortedByWinner));
      }).catchError((Object error, StackTrace stack) {
        state.completed = true;
        state.sw.stop();
        final bool hardError = _isHardError(error);
        records.add(AttemptRecord(
          attemptIndex: idx,
          ip: ip.addressString,
          outcome: state.aborted
              ? AttemptOutcome.abortedByWinner
              : AttemptOutcome.failed,
          durationMs: state.sw.elapsedMilliseconds,
          error: error,
        ));
        if (winner.isCompleted) {
          // Already won/lost; swallow.
          return;
        }
        if (!state.aborted) {
          _emit(AttemptFailed(
            host: host,
            ip: ip.addressString,
            attemptIndex: idx,
            error: error,
            durationMs: state.sw.elapsedMilliseconds,
          ));
          _options.logger.log(FailoverLogLevel.warn, 'attempt_failed',
              fields: <String, Object?>{
                'host': host,
                'ip': ip.addressString,
                'attempt': idx,
                'hard': hardError,
                'error': error.toString(),
              });
          _cache.markUnavailable(host, ip.address);
        }
        if (winner.isCompleted) return;
        if (_allAttemptsTerminated(attempts) && nextIndex < candidates.length) {
          // No remaining live attempts; try the next IP now.
          if (hardError) {
            failoverTimer?.cancel();
            failoverTimer = null;
          }
          startNextAttempt();
          _armFailoverTimer();
        } else if (_allAttemptsTerminated(attempts) &&
            nextIndex >= candidates.length) {
          // Exhausted.
          overall.stop();
          cancelTimers();
          _emit(RequestExhausted(
            host: host,
            attempts: List<AttemptRecord>.unmodifiable(records),
            idempotencyKey: idempotencyKey,
          ));
          winner.completeError(
            DioException(
              requestOptions: requestOptions,
              type: DioExceptionType.connectionTimeout,
              error: FailoverExhaustedError(
                host: host,
                attempts: List<AttemptRecord>.unmodifiable(records),
                idempotencyKey: idempotencyKey,
                overallDurationMs: overall.elapsedMilliseconds,
              ),
              message: 'All ${records.length} IP attempts to $host failed',
            ),
          );
        } else if (hardError) {
          // Live attempts exist OR we have IPs left; on hard error trigger
          // next now to skip the wait.
          if (nextIndex < candidates.length) {
            failoverTimer?.cancel();
            failoverTimer = null;
            startNextAttempt();
            _armFailoverTimer();
          }
        }
      });
    }

    void armFailoverTimer() {
      failoverTimer?.cancel();
      if (nextIndex >= candidates.length) return;
      if (winner.isCompleted) return;
      final Duration t = _methodFailoverTimeout(requestOptions, host);
      failoverTimer = Timer(t, () {
        if (winner.isCompleted) return;
        if (nextIndex >= candidates.length) return;
        startNextAttempt();
        armFailoverTimer();
      });
    }

    _armFailoverTimer = armFailoverTimer;

    // Wire up overall timeout.
    final Duration deadline = _overallDeadline(requestOptions, host);
    overallTimer = Timer(deadline, () {
      if (winner.isCompleted) return;
      overall.stop();
      cancelTimers();
      records.add(AttemptRecord(
        attemptIndex: -1,
        ip: lastTriedIp ?? '',
        outcome: AttemptOutcome.abortedByOverallTimeout,
        durationMs: overall.elapsedMilliseconds,
      ));
      _emit(RequestExhausted(
        host: host,
        attempts: List<AttemptRecord>.unmodifiable(records),
        idempotencyKey: idempotencyKey,
      ));
      winner.completeError(
        DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.connectionTimeout,
          error: FailoverExhaustedError(
            host: host,
            attempts: List<AttemptRecord>.unmodifiable(records),
            idempotencyKey: idempotencyKey,
            overallDurationMs: overall.elapsedMilliseconds,
            reason: 'overall_timeout',
          ),
          message: 'Overall request timeout (${deadline.inMilliseconds}ms) '
              'exceeded for $host',
        ),
      );
      unawaited(abortAll(AttemptOutcome.abortedByOverallTimeout));
    });

    // Wire up outer cancel.
    if (cancelFuture != null) {
      cancelSub = cancelFuture.asStream().listen((_) {
        if (winner.isCompleted) return;
        overall.stop();
        cancelTimers();
        records.add(AttemptRecord(
          attemptIndex: -1,
          ip: lastTriedIp ?? '',
          outcome: AttemptOutcome.abortedByCancel,
          durationMs: overall.elapsedMilliseconds,
        ));
        winner.completeError(
          DioException.requestCancelled(
            requestOptions: requestOptions,
            reason: 'cancelled',
            stackTrace: StackTrace.current,
          ),
        );
        unawaited(abortAll(AttemptOutcome.abortedByCancel));
      });
    }

    startNextAttempt();
    armFailoverTimer();

    try {
      return await winner.future;
    } finally {
      cancelTimers();
      await cancelSub?.cancel();
    }
  }

  // Late-bound reference so closures inside _runCoordinator can re-arm
  // the timer from each other without forward-declaration noise.
  void Function() _armFailoverTimer = () {};

  bool _allAttemptsTerminated(List<_AttemptState> attempts) {
    for (final _AttemptState a in attempts) {
      if (!a.completed && !a.aborted) return false;
    }
    return true;
  }

  bool _isHardError(Object e) {
    if (e is HandshakeException) return true;
    if (e is TlsException) return true;
    if (e is SocketException) {
      final OSError? os = e.osError;
      if (os == null) return false;
      // Linux ECONNREFUSED=111, Windows WSAECONNREFUSED=10061,
      // macOS ECONNREFUSED=61. Also ECONNRESET variants. Treat any error
      // with a non-zero errno as hard for fast-path purposes.
      return true;
    }
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionError) return true;
      if (e.type == DioExceptionType.badCertificate) return true;
    }
    return false;
  }

  RequestOptions _cloneWithHeaders(
    RequestOptions original, {
    required String idempotencyKey,
    required String? previousIp,
    required String host,
  }) {
    final RequestOptions cloned = original.copyWith();
    if (_options.enableFailoverHeadersFor(host)) {
      cloned.headers[FailoverHeaders.idempotencyKey] = idempotencyKey;
      if (previousIp != null) {
        cloned.headers[FailoverHeaders.previousIp] = previousIp;
      } else {
        cloned.headers.remove(FailoverHeaders.previousIp);
      }
    }
    return cloned;
  }

  void _annotateResponse(
    ResponseBody body, {
    required String host,
    required String ip,
    required List<AttemptRecord> attempts,
    required String idempotencyKey,
    required int totalMs,
  }) {
    body.extra[FailoverExtraKeys.winningIp] = ip;
    body.extra[FailoverExtraKeys.attempts] = attempts;
    body.extra[FailoverExtraKeys.idempotencyKey] = idempotencyKey;
    body.extra[FailoverExtraKeys.totalMs] = totalMs;
  }

  void _logMisconfigWarnings() {
    if (!_options.enableMisconfigWarnings) return;
    if (_misconfigLogged) return;
    _misconfigLogged = true;
    final FailoverLogger l = _options.logger;
    if (_options.getConnectTimeout > _options.defaultConnectTimeout) {
      l.log(FailoverLogLevel.warn,
          'misconfig: getConnectTimeout > defaultConnectTimeout');
    }
    if (_options.maxIpAttempts == 1 && _options.enableLatencyProbe) {
      l.log(FailoverLogLevel.warn,
          'misconfig: maxIpAttempts == 1 makes latency probes wasted work');
    }
    final Duration budget = _options.defaultConnectTimeout *
        _options.maxIpAttempts;
    if (_options.overallTimeout < budget) {
      l.log(FailoverLogLevel.warn,
          'misconfig: overallTimeout (${_options.overallTimeout}) is less '
          'than maxIpAttempts × defaultConnectTimeout ($budget); '
          'the fail-over budget will be cut short.');
    }
    if (_options.maxIpAttempts > 5) {
      l.log(FailoverLogLevel.warn,
          'misconfig: maxIpAttempts=${_options.maxIpAttempts} is unusually '
          'high; verify intent.');
    }
    if (_options.unavailableCooldownInitial > _options.overallTimeout) {
      l.log(FailoverLogLevel.warn,
          'misconfig: unavailableCooldownInitial > overallTimeout');
    }
    if (kDebugMode) {
      assert(_options.maxIpAttempts >= 1,
          'maxIpAttempts must be >= 1, got ${_options.maxIpAttempts}');
    }
  }
}

class _AttemptState {
  _AttemptState(this.index, this.ip)
      : abortCompleter = Completer<void>(),
        sw = Stopwatch()..start();

  final int index;
  final IpEntry ip;
  final Completer<void> abortCompleter;
  final Stopwatch sw;
  bool completed = false;
  bool aborted = false;
}

class _BufferedBody {
  const _BufferedBody({required this.bytes, required this.singleAttempt});
  final Uint8List? bytes;
  final bool singleAttempt;
}
