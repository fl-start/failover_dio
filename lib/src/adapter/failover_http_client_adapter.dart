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
import 'happy_eyeballs_connect_race.dart';
import '../observability/attempt_record.dart';
import '../observability/failover_event.dart';
import '../observability/failover_logger.dart';
import '../util/build_mode.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';
import '../util/timeline.dart';

/// `HttpClientAdapter` that adds DNS-aware IP failover, parallel TCP Happy
/// Eyeballs connect racing, idempotency/observability headers, and
/// CancelToken-aware orchestration on top of Dio's standard transport.
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

    final int parallelWidth =
        _resolveMaxIpAttempts(options, host, singleAttemptOnly);
    final List<IpEntry> allEntries = _cache.orderedEntries(host);
    if (allEntries.isEmpty) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'No candidate IPs available for $host',
      );
    }

    return _runHappyEyeballsCoordinator(
      requestOptions: options,
      allEntries: allEntries,
      bodyBytes: bodyBytes,
      singleAttemptOnly: singleAttemptOnly,
      cancelFuture: cancelFuture,
      host: host,
      port: port,
      parallelWidth: parallelWidth,
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

  Future<ResponseBody> _runHappyEyeballsCoordinator({
    required RequestOptions requestOptions,
    required List<IpEntry> allEntries,
    required Uint8List? bodyBytes,
    required bool singleAttemptOnly,
    required Future<void>? cancelFuture,
    required String host,
    required int port,
    required int parallelWidth,
  }) async {
    final String idempotencyKey =
        _options.idempotencyKeyGenerator.generate();
    final Stopwatch overall = Stopwatch()..start();
    final List<AttemptRecord> records = <AttemptRecord>[];
    final bool probeEnabled = _options.enableLatencyProbeFor(host);
    const HappyEyeballsConnectRace connectRace = HappyEyeballsConnectRace();

    List<IpEntry> remaining = List<IpEntry>.of(allEntries);
    int waveIndex = 0;
    String? previousIp;
    String? lastTriedIp;

    final Completer<void> httpAbort = Completer<void>();
    Timer? overallTimer;
    StreamSubscription<void>? cancelSub;
    bool cancelled = false;

    final Future<void> connectAbort = cancelFuture == null
        ? httpAbort.future
        : Future.any<void>(<Future<void>>[cancelFuture, httpAbort.future]);

    void cancelOverallTimer() {
      overallTimer?.cancel();
      overallTimer = null;
    }

    Never throwExhausted() {
      overall.stop();
      cancelOverallTimer();
      _emit(RequestExhausted(
        host: host,
        attempts: List<AttemptRecord>.unmodifiable(records),
        idempotencyKey: idempotencyKey,
      ));
      throw DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.connectionTimeout,
        error: FailoverExhaustedError(
          host: host,
          attempts: List<AttemptRecord>.unmodifiable(records),
          idempotencyKey: idempotencyKey,
          overallDurationMs: overall.elapsedMilliseconds,
        ),
        message: 'All IP attempts to $host failed',
      );
    }

    final Duration deadline = _overallDeadline(requestOptions, host);
    overallTimer = Timer(deadline, () {
      if (!httpAbort.isCompleted) httpAbort.complete();
    });

    if (cancelFuture != null) {
      cancelSub = cancelFuture.asStream().listen((_) {
        if (cancelled) return;
        cancelled = true;
        if (!httpAbort.isCompleted) httpAbort.complete();
      });
    }

    try {
      while (remaining.isNotEmpty) {
        if (overall.elapsed >= deadline) {
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
          throw DioException(
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
          );
        }

        if (cancelled) {
          overall.stop();
          records.add(AttemptRecord(
            attemptIndex: -1,
            ip: lastTriedIp ?? '',
            outcome: AttemptOutcome.abortedByCancel,
            durationMs: overall.elapsedMilliseconds,
          ));
          throw DioException.requestCancelled(
            requestOptions: requestOptions,
            reason: 'cancelled',
            stackTrace: StackTrace.current,
          );
        }

        final List<IpEntry> batch =
            remaining.take(parallelWidth).toList(growable: false);
        if (batch.isEmpty) break;

        if (waveIndex > 0) FailoverMetrics.instance.incFailovers();

        ConnectRaceWinner? raceWinner;
        final Map<String, int?> connectLatencies = <String, int?>{};

        // Warm-path skip (mirrors curl_fo behaviour): when the batch already
        // has fresh latency rankings, bypass the TCP connect race entirely and
        // go straight to HTTP on the top-ranked IP. The race is only needed on
        // a cold cache (first request) or after topology changes force a re-rank.
        final bool rankingsFresh =
            probeEnabled && _probeScheduler.hasFreshLatencyRanking(batch);

        if (probeEnabled && !rankingsFresh) {
          try {
            raceWinner = await connectRace
                .race(
              entries: batch,
              port: port,
              timeout: _options.probeTimeout,
              abortFuture: connectAbort,
              onConnectComplete: (IpEntry entry, int? latencyMs, int order) {
                connectLatencies[entry.addressString] = latencyMs;
                _cache.recordLatency(host, entry.address, latencyMs);
                _emit(LatencyProbed(
                  host: host,
                  ip: entry.addressString,
                  latencyMs: latencyMs,
                  success: latencyMs != null,
                  completionOrder: order,
                ));
              },
            )
                .timeout(
              _options.probeTimeout + const Duration(milliseconds: 250),
              onTimeout: () => null,
            );
          } on SocketException {
            if (cancelled) {
              throw DioException.requestCancelled(
                requestOptions: requestOptions,
                reason: 'cancelled',
                stackTrace: StackTrace.current,
              );
            }
            raceWinner = null;
          }
        } else {
          // Either probing is disabled or rankings are warm: use top of batch.
          raceWinner = ConnectRaceWinner(entry: batch.first, connectMs: 0);
        }

        if (raceWinner == null) {
          for (final IpEntry e in batch) {
            _cache.markUnavailable(host, e.address);
            records.add(AttemptRecord(
              attemptIndex: waveIndex,
              ip: e.addressString,
              outcome: AttemptOutcome.failed,
              durationMs: connectLatencies[e.addressString] ?? 0,
              error: const SocketException('TCP connect race failed'),
            ));
            _emit(AttemptFailed(
              host: host,
              ip: e.addressString,
              attemptIndex: waveIndex,
              error: const SocketException('TCP connect race failed'),
              durationMs: connectLatencies[e.addressString] ?? 0,
            ));
          }
          remaining = remaining.sublist(batch.length);
          waveIndex++;
          continue;
        }

        final IpEntry target = raceWinner.entry;
        lastTriedIp = target.addressString;

        for (final IpEntry e in batch) {
          if (e.addressString == target.addressString) continue;
          final int? ms = connectLatencies[e.addressString];
          if (ms == null) continue;
          records.add(AttemptRecord(
            attemptIndex: waveIndex,
            ip: e.addressString,
            outcome: AttemptOutcome.abortedByConnectRace,
            durationMs: ms,
          ));
          _emit(AttemptAborted(
            host: host,
            ip: e.addressString,
            attemptIndex: waveIndex,
            reason: AttemptOutcome.abortedByConnectRace,
          ));
        }

        _emit(AttemptStarted(
          host: host,
          ip: target.addressString,
          attemptIndex: waveIndex,
          idempotencyKey: idempotencyKey,
          previousIp: previousIp,
        ));
        _options.logger.log(FailoverLogLevel.debug, 'attempt_started',
            fields: <String, Object?>{
              'host': host,
              'ip': target.addressString,
              'attempt': waveIndex,
              'idem': idempotencyKey,
              if (previousIp != null) 'previousIp': previousIp,
              'connectMs': raceWinner.connectMs,
            });

        final RequestOptions cloned = _cloneWithHeaders(
          requestOptions,
          idempotencyKey: idempotencyKey,
          previousIp: previousIp,
          host: host,
        );
        final Stream<Uint8List>? freshBody = bodyBytes == null
            ? null
            : Stream<Uint8List>.fromIterable(<Uint8List>[bodyBytes]);
        final IOHttpClientAdapter adapter =
            _pinnedAdapterFor(host, target.address);
        final Stopwatch httpSw = Stopwatch()..start();

        try {
          final ResponseBody body = await adapter.fetch(
            cloned,
            freshBody,
            cancelFuture,
          );
          httpSw.stop();

          // Opt-in "Redirect-To-Peer" failover.  Only fires when:
          //  1. redirectToPeerStatus is configured (non-null), AND
          //  2. the response status exactly matches that code, AND
          //  3. the request body can still be replayed (!singleAttemptOnly).
          // All other HTTP responses — including standard 4xx and 5xx — are
          // returned to the caller immediately without retrying a different IP.
          final int? redirectCode =
              _options.redirectToPeerStatusFor(host);
          if (!singleAttemptOnly &&
              redirectCode != null &&
              body.statusCode == redirectCode) {
            records.add(AttemptRecord(
              attemptIndex: waveIndex,
              ip: target.addressString,
              outcome: AttemptOutcome.failedOnStatus,
              durationMs: httpSw.elapsedMilliseconds,
              statusCode: body.statusCode,
            ));
            _emit(AttemptFailed(
              host: host,
              ip: target.addressString,
              attemptIndex: waveIndex,
              error: Exception('HTTP ${body.statusCode} triggers failover'),
              durationMs: httpSw.elapsedMilliseconds,
            ));
            // Short transient cooldown; consecutive-failure counter unchanged.
            _cache.markUnavailable(host, target.address, transient: true);
            previousIp = target.addressString;
            remaining.removeWhere(
              (IpEntry e) => e.addressString == target.addressString,
            );
            waveIndex++;
            FailoverMetrics.instance.incFailovers();
            // Drain the response body to return the connection to the pool.
            unawaited(body.stream.drain<void>().catchError((_) {}));
            continue;
          }

          records.add(AttemptRecord(
            attemptIndex: waveIndex,
            ip: target.addressString,
            outcome: AttemptOutcome.succeeded,
            durationMs: httpSw.elapsedMilliseconds,
            statusCode: body.statusCode,
          ));
          _emit(AttemptSucceeded(
            host: host,
            ip: target.addressString,
            attemptIndex: waveIndex,
            statusCode: body.statusCode,
            durationMs: httpSw.elapsedMilliseconds,
          ));
          _cache.markAvailable(host, target.address);
          overall.stop();
          final List<AttemptRecord> sortedRecords =
              List<AttemptRecord>.of(records)
                ..sort((AttemptRecord a, AttemptRecord b) =>
                    a.attemptIndex.compareTo(b.attemptIndex));
          _annotateResponse(
            body,
            host: host,
            ip: target.addressString,
            attempts: List<AttemptRecord>.unmodifiable(sortedRecords),
            idempotencyKey: idempotencyKey,
            totalMs: overall.elapsedMilliseconds,
          );
          return body;
        } on DioException catch (e) {
          httpSw.stop();
          if (CancelToken.isCancel(e)) rethrow;
          records.add(AttemptRecord(
            attemptIndex: waveIndex,
            ip: target.addressString,
            outcome: AttemptOutcome.failed,
            durationMs: httpSw.elapsedMilliseconds,
            error: e,
          ));
          _emit(AttemptFailed(
            host: host,
            ip: target.addressString,
            attemptIndex: waveIndex,
            error: e,
            durationMs: httpSw.elapsedMilliseconds,
          ));
          _cache.markUnavailable(host, target.address);
          previousIp = target.addressString;
          remaining.removeWhere(
            (IpEntry e) => e.addressString == target.addressString,
          );
          waveIndex++;
        } catch (e, s) {
          httpSw.stop();
          records.add(AttemptRecord(
            attemptIndex: waveIndex,
            ip: target.addressString,
            outcome: AttemptOutcome.failed,
            durationMs: httpSw.elapsedMilliseconds,
            error: e,
          ));
          _emit(AttemptFailed(
            host: host,
            ip: target.addressString,
            attemptIndex: waveIndex,
            error: e,
            durationMs: httpSw.elapsedMilliseconds,
          ));
          _cache.markUnavailable(host, target.address);
          previousIp = target.addressString;
          remaining.removeWhere(
            (IpEntry e) => e.addressString == target.addressString,
          );
          waveIndex++;
          if (e is DioException) rethrow;
          Error.throwWithStackTrace(e, s);
        }
      }

      throwExhausted();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) && cancelled) {
        records.add(AttemptRecord(
          attemptIndex: -1,
          ip: lastTriedIp ?? '',
          outcome: AttemptOutcome.abortedByCancel,
          durationMs: overall.elapsedMilliseconds,
        ));
      }
      if (overall.elapsed >= deadline && !CancelToken.isCancel(e)) {
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
        throw DioException(
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
        );
      }
      rethrow;
    } finally {
      cancelOverallTimer();
      await cancelSub?.cancel();
    }
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
          'misconfig: maxIpAttempts == 1 disables parallel connect racing');
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

class _BufferedBody {
  const _BufferedBody({required this.bytes, required this.singleAttempt});
  final Uint8List? bytes;
  final bool singleAttempt;
}
