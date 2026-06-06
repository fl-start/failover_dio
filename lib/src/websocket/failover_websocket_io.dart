import 'dart:async';
import 'dart:io';

import '../adapter/failover_http_client_adapter.dart';
import '../adapter/happy_eyeballs_connect_race.dart';
import '../cache/host_ip_cache.dart';
import '../cache/ip_entry.dart';
import '../config/failover_headers.dart';
import '../config/failover_options.dart';
import '../errors/failover_exhausted_error.dart';
import '../latency/probe_scheduler.dart';
import '../observability/attempt_record.dart';
import '../observability/failover_event.dart';
import '../util/hostname_normalizer.dart';
import '../util/metrics.dart';

/// DNS-aware WebSocket client with ranked-IP connect and curl_fo-style
/// reconnect failover.
///
/// Mirrors [curl_fo](https://github.com/idrto/curl_fo) WebSocket behaviour:
///
/// - **Initial connect**: DNS cache + latency-ranked IPs; cold multi-IP hosts
///   run a parallel TCP Happy Eyeballs race, then upgrade the winner;
///   warm hosts try ranked IPs sequentially.
/// - **Reconnect on transport failure** ([send] error or [reconnect]):
///   retry the **same IP once**, then advance to the **next ranked IP** and
///   repeat until exhausted. The same [FailoverWebSocket] handle stays valid;
///   [socket] and [winningIp] reflect the new connection after reconnect.
///
/// `ws://` is fully supported with per-IP pinning. `wss://` uses stock
/// `WebSocket.connect` without IP pinning (same v0.1 limitation as HTTPS).
class FailoverWebSocket {
  FailoverWebSocket._({
    required WebSocket socket,
    required HttpClient httpClient,
    required this.host,
    required this.winningIp,
    required this.idempotencyKey,
    required List<AttemptRecord> connectAttempts,
    required _WebSocketSession session,
  })  : _socket = socket,
        _httpClient = httpClient,
        connectAttempts = List<AttemptRecord>.unmodifiable(connectAttempts),
        _session = session;

  WebSocket _socket;
  HttpClient _httpClient;

  /// IP string for the active connection (updated in-place after [reconnect]).
  String winningIp;

  /// Active WebSocket (updated in-place after [reconnect]).
  WebSocket get socket => _socket;

  /// Normalized hostname from the connect URL.
  final String host;

  /// Stable idempotency key sent on connect (and reconnect) attempts.
  final String idempotencyKey;

  /// Records for the initial connect sequence.
  final List<AttemptRecord> connectAttempts;

  final _WebSocketSession _session;

  bool _closed = false;

  /// Opens a WebSocket with DNS-aware IP failover.
  static Future<FailoverWebSocket> connect(
    String url, {
    FailoverOptions? failoverOptions,
    HostIpCache? cache,
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) async {
    final FailoverHttpClientAdapter adapter = FailoverHttpClientAdapter(
      options: failoverOptions,
      cache: cache,
    );
    final _WebSocketSession session = _WebSocketSession(adapter: adapter);
    return session.connect(
      Uri.parse(url),
      protocols: protocols,
      headers: headers,
    );
  }

  /// Incoming messages from the active [socket] (updates after [reconnect]).
  Stream<dynamic> get stream => _socket;

  /// Sends [data] on the socket, reconnecting once on transport failure
  /// (curl_fo `cf_ws_send` semantics).
  Future<void> send(dynamic data) async {
    _ensureOpen();
    try {
      _socket.add(data);
    } catch (e) {
      if (!await _session.reconnectAfterFailure(this, phase: 'send')) {
        rethrow;
      }
      _socket.add(data);
    }
  }

  /// Attempts reconnect using the curl_fo policy (same IP once, then next).
  Future<void> reconnect() async {
    _ensureOpen();
    final bool ok =
        await _session.reconnectAfterFailure(this, phase: 'manual');
    if (!ok) {
      throw StateError('WebSocket reconnect exhausted for $host');
    }
  }

  /// Swaps the active transport (called by [_WebSocketSession] on reconnect).
  void _replaceTransport({
    required WebSocket socket,
    required HttpClient httpClient,
    required String ip,
  }) {
    _socket = socket;
    _httpClient = httpClient;
    winningIp = ip;
  }

  /// Closes the WebSocket and releases the pinned [HttpClient].
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (_closed) return;
    _closed = true;
    _session.detach();
    try {
      await _socket.close(closeCode, closeReason);
    } catch (_) {
      // Best-effort close.
    }
    _httpClient.close(force: true);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('FailoverWebSocket is closed');
    }
  }
}

/// Mutable session state for connect + reconnect.
class _WebSocketSession {
  _WebSocketSession({required FailoverHttpClientAdapter adapter})
      : _options = adapter.options,
        _cache = adapter.cache,
        _probeScheduler = adapter.probeScheduler;

  final FailoverOptions _options;
  final HostIpCache _cache;
  final ProbeScheduler _probeScheduler;

  static const HappyEyeballsConnectRace _connectRace =
      HappyEyeballsConnectRace();

  late Uri _uri;
  late String _host;
  late int _port;
  late List<IpEntry> _ranked;
  int _currentIndex = 0;
  bool _retrySame = false;
  String? _cachedIdem;
  String? _previousIp;
  int _connectAttemptIndex = 0;
  final List<AttemptRecord> _connectRecords = <AttemptRecord>[];

  String _idem() =>
      _cachedIdem ??= _options.idempotencyKeyGenerator.generate();

  void detach() {}

  Future<FailoverWebSocket> connect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) async {
    _uri = uri;
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(uri, 'uri', 'scheme must be ws or wss');
    }
    _host = HostnameNormalizer.normalize(uri.host);
    _port = uri.hasPort
        ? uri.port
        : (uri.scheme == 'wss' ? 443 : 80);

    if (_shouldBypass(uri)) {
      final WebSocket ws = await WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: headers,
      );
      final FailoverWebSocket handle = FailoverWebSocket._(
        socket: ws,
        httpClient: HttpClient()..close(force: true),
        host: _host,
        winningIp: uri.host,
        idempotencyKey: _idem(),
        connectAttempts: const <AttemptRecord>[],
        session: this,
      );
      return handle;
    }

    if (uri.scheme == 'wss') {
      final WebSocket ws = await WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: _mergeHeaders(headers),
      );
      final FailoverWebSocket handle = FailoverWebSocket._(
        socket: ws,
        httpClient: HttpClient()..close(force: true),
        host: _host,
        winningIp: _host,
        idempotencyKey: _idem(),
        connectAttempts: const <AttemptRecord>[],
        session: this,
      );
      return handle;
    }

    final List<IpEntry> entries = await _cache.resolveIfNeeded(_host);
    if (entries.isEmpty) {
      throw SocketException('DNS resolution for $_host returned no addresses');
    }

    _ranked = _cache.orderedEntries(_host);
    _currentIndex = 0;
    _retrySame = false;
    _connectAttemptIndex = 0;
    _connectRecords.clear();

    if (entries.length == 1 && _options.singleIpFastPathFor(_host)) {
      final _PinnedWs pinned = await _connectToEntry(
        entries.first,
        headers: headers,
        protocols: protocols,
        phase: 'single-ip',
      );
      return _wrapActive(pinned, entries.first.addressString);
    }

    final List<IpEntry> batch = _ranked
        .take(_options.maxIpAttemptsFor(_host))
        .toList(growable: false);
    final bool probeEnabled = _options.enableLatencyProbeFor(_host);
    final bool rankingsFresh =
        probeEnabled && _probeScheduler.hasFreshLatencyRanking(batch);

    if (probeEnabled && !rankingsFresh && batch.length > 1) {
      final ConnectRaceWinner? winner = await _connectRace
          .race(
            entries: batch,
            port: _port,
            timeout: _options.probeTimeout,
            onConnectComplete: (IpEntry entry, int? latencyMs, int order) {
              _cache.recordLatency(_host, entry.address, latencyMs);
              _emit(LatencyProbed(
                host: _host,
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
      if (winner != null) {
        _currentIndex = _indexOfEntry(winner.entry);
        try {
          final _PinnedWs pinned = await _connectToEntry(
            winner.entry,
            headers: headers,
            protocols: protocols,
            phase: 'race',
          );
          return _wrapActive(pinned, winner.entry.addressString);
        } on Object catch (e) {
          _cache.markUnavailable(_host, winner.entry.address);
          _recordFailed(winner.entry.addressString, e);
        }
      }
    }

    for (int i = 0; i < _ranked.length; i++) {
      _currentIndex = i;
      final IpEntry entry = _ranked[i];
      try {
        final _PinnedWs pinned = await _connectToEntry(
          entry,
          headers: headers,
          protocols: protocols,
          phase: 'sequential',
        );
        return _wrapActive(pinned, entry.addressString);
      } on Object catch (e) {
        _cache.markUnavailable(_host, entry.address);
        _recordFailed(entry.addressString, e);
      }
    }

    throw FailoverExhaustedError(
      host: _host,
      attempts: List<AttemptRecord>.unmodifiable(_connectRecords),
      idempotencyKey: _idem(),
      overallDurationMs: 0,
    );
  }

  /// curl_fo reconnect: same IP once, then next ranked IP.
  Future<bool> reconnectAfterFailure(
    FailoverWebSocket handle, {
    required String phase,
  }) async {
    if (_ranked.length <= 1) {
      return false;
    }

    _refreshRankedFromCache();

    _emit(WebSocketReconnecting(
      host: _host,
      ip: _ranked[_currentIndex].addressString,
      phase: phase,
    ));

    if (!_retrySame) {
      _retrySame = true;
      if (await _tryReconnectToIndex(handle, _currentIndex,
          phase: 'reconnect-same')) {
        return true;
      }
    }

    _retrySame = false;
    _currentIndex++;
    if (_currentIndex >= _ranked.length) {
      return false;
    }

    return _tryReconnectToIndex(handle, _currentIndex, phase: 'reconnect-next');
  }

  Future<bool> _tryReconnectToIndex(
    FailoverWebSocket handle,
    int index, {
    required String phase,
  }) async {
    final IpEntry entry = _ranked[index];

    try {
      await handle._socket.close();
    } catch (_) {}
    handle._httpClient.close(force: true);

    try {
      final _PinnedWs pinned = await _connectToEntry(
        entry,
        headers: null,
        protocols: null,
        phase: phase,
        isReconnect: true,
      );
      handle._replaceTransport(
        socket: pinned.socket,
        httpClient: pinned.client,
        ip: entry.addressString,
      );
      _emit(WebSocketReconnected(
        host: _host,
        ip: entry.addressString,
        phase: phase,
      ));
      return true;
    } on Object catch (e) {
      _cache.markUnavailable(_host, entry.address);
      _emit(WebSocketReconnectFailed(
        host: _host,
        ip: entry.addressString,
        error: e,
        phase: phase,
      ));
      return false;
    }
  }

  void _refreshRankedFromCache() {
    if (_ranked.isEmpty) return;
    final String currentIp = _ranked[_currentIndex].addressString;
    final List<IpEntry> fresh = _cache.orderedEntries(_host);
    if (fresh.length <= _ranked.length) return;
    _ranked = fresh;
    _currentIndex = 0;
    for (int i = 0; i < _ranked.length; i++) {
      if (_ranked[i].addressString == currentIp) {
        _currentIndex = i;
        break;
      }
    }
  }

  FailoverWebSocket _wrapActive(_PinnedWs pinned, String ip) {
    _previousIp = null;
    final FailoverWebSocket handle = FailoverWebSocket._(
      socket: pinned.socket,
      httpClient: pinned.client,
      host: _host,
      winningIp: ip,
      idempotencyKey: _idem(),
      connectAttempts: List<AttemptRecord>.unmodifiable(_connectRecords),
      session: this,
    );
    _emit(WebSocketConnected(host: _host, ip: ip));
    FailoverMetrics.instance.incRequests();
    return handle;
  }

  Future<_PinnedWs> _connectToEntry(
    IpEntry entry, {
    Map<String, String>? headers,
    Iterable<String>? protocols,
    required String phase,
    bool isReconnect = false,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    final int attemptIndex = isReconnect ? -1 : _connectAttemptIndex++;
    _emit(AttemptStarted(
      host: _host,
      ip: entry.addressString,
      attemptIndex: attemptIndex,
      idempotencyKey: _idem(),
      previousIp: _previousIp,
    ));

    final HttpClient client = HttpClient()
      ..connectionTimeout = _options.probeTimeout
      ..connectionFactory =
          (Uri uri, String? proxyHost, int? proxyPort) {
        return Socket.startConnect(entry.address, uri.port);
      };

    try {
      final WebSocket ws = await WebSocket.connect(
        _uri.toString(),
        protocols: protocols,
        headers: _mergeHeaders(headers),
        customClient: client,
      ).timeout(_options.probeTimeout);
      sw.stop();
      _cache.markAvailable(_host, entry.address);
      _previousIp = entry.addressString;
      if (!isReconnect) {
        _connectRecords.add(AttemptRecord(
          attemptIndex: attemptIndex,
          ip: entry.addressString,
          outcome: AttemptOutcome.succeeded,
          durationMs: sw.elapsedMilliseconds,
        ));
      }
      _emit(AttemptSucceeded(
        host: _host,
        ip: entry.addressString,
        attemptIndex: attemptIndex,
        statusCode: 101,
        durationMs: sw.elapsedMilliseconds,
      ));
      return _PinnedWs(socket: ws, client: client);
    } on Object catch (e) {
      sw.stop();
      client.close(force: true);
      if (!isReconnect) {
        _recordFailed(entry.addressString, e, attemptIndex: attemptIndex);
      }
      _emit(AttemptFailed(
        host: _host,
        ip: entry.addressString,
        attemptIndex: attemptIndex,
        error: e,
        durationMs: sw.elapsedMilliseconds,
      ));
      rethrow;
    }
  }

  void _recordFailed(String ip, Object e, {int? attemptIndex}) {
    _connectRecords.add(AttemptRecord(
      attemptIndex: attemptIndex ?? _connectAttemptIndex - 1,
      ip: ip,
      outcome: AttemptOutcome.failed,
      durationMs: 0,
      error: e,
    ));
  }

  Map<String, String> _mergeHeaders(Map<String, String>? headers) {
    final Map<String, String> out = <String, String>{
      if (headers != null) ...headers,
    };
    if (_options.enableFailoverHeadersFor(_host)) {
      out[FailoverHeaders.idempotencyKey] = _idem();
      if (_previousIp != null) {
        out[FailoverHeaders.previousIp] = _previousIp!;
      }
    }
    return out;
  }

  int _indexOfEntry(IpEntry entry) {
    for (int i = 0; i < _ranked.length; i++) {
      if (_ranked[i].addressString == entry.addressString) return i;
    }
    return 0;
  }

  bool _shouldBypass(Uri uri) {
    final String host = uri.host;
    if (host.isEmpty) return true;
    if (host.startsWith('[') && host.endsWith(']')) return true;
    if (InternetAddress.tryParse(host) != null) return true;
    final String norm = HostnameNormalizer.normalize(host);
    if (norm == 'localhost') return true;
    if (norm.endsWith('.local')) return true;
    return false;
  }

  void _emit(FailoverEvent e) {
    try {
      _options.onEvent?.call(e);
    } catch (_) {
      // Never let listeners crash the session.
    }
  }
}

class _PinnedWs {
  const _PinnedWs({required this.socket, required this.client});
  final WebSocket socket;
  final HttpClient client;
}
