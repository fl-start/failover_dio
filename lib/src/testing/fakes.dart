import 'dart:io';

import '../dns/dns_resolver.dart';
import '../latency/latency_probe.dart';
import '../util/clock.dart';
import '../util/hostname_normalizer.dart';
import '../util/idempotency_key_generator.dart';

/// Test [Clock] whose current time can be advanced manually.
class FakeClock implements Clock {
  /// Creates a clock starting at [initial].
  FakeClock(DateTime initial) : _now = initial;

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Advances the clock by [d].
  void advance(Duration d) {
    _now = _now.add(d);
  }

  /// Sets the clock to [t].
  void set(DateTime t) {
    _now = t;
  }
}

/// Test [DnsResolver] returning canned answers.
class FakeDnsResolver implements DnsResolver {
  /// Creates a resolver with [responses] keyed by hostname (case-insensitive,
  /// trailing-dot safe).
  FakeDnsResolver(
    this.responses, {
    this.ttl = const Duration(seconds: 60),
  });

  /// Map of normalized host → list of IP strings.
  final Map<String, List<String>> responses;

  /// TTL returned with every answer.
  final Duration ttl;

  /// Increments each call; useful for asserting how many times resolve fired.
  int callCount = 0;

  @override
  Future<DnsAnswer> resolve(String host) async {
    callCount++;
    final String h = HostnameNormalizer.normalize(host);
    final List<String>? ips = responses[h];
    if (ips == null || ips.isEmpty) {
      throw SocketException('FakeDnsResolver has no entry for $h');
    }
    return DnsAnswer(
      addresses: ips
          .map((String s) => InternetAddress(s))
          .toList(growable: false),
      ttl: ttl,
    );
  }
}

/// Test [LatencyProbe] returning canned latencies.
class FakeLatencyProbe implements LatencyProbe {
  /// Creates a probe with per-IP [latencies] in ms.
  ///
  /// Optional [delays] simulate connect time before returning [latencies].
  FakeLatencyProbe(
    this.latencies, {
    this.delays = const <String, Duration>{},
  });

  /// IP string → ms; missing entries probe as null (timeout).
  final Map<String, int?> latencies;

  /// IP string → artificial connect delay before returning.
  final Map<String, Duration> delays;

  /// Each probe call increments this.
  int callCount = 0;

  @override
  Future<int?> probe(InternetAddress ip, int port, {Duration? timeout}) async {
    callCount++;
    final Duration? delay = delays[ip.address];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    return latencies[ip.address];
  }
}

/// Deterministic [IdempotencyKeyGenerator] for tests.
class FakeIdempotencyKeyGenerator implements IdempotencyKeyGenerator {
  /// Creates a generator that returns the [keys] in order, then repeats the
  /// last key forever once the iterator is drained.
  FakeIdempotencyKeyGenerator(List<String> keys) : _keys = List<String>.of(keys);

  final List<String> _keys;
  int _index = 0;

  @override
  String generate() {
    if (_keys.isEmpty) return 'fake_idem_key';
    if (_index >= _keys.length) return _keys.last;
    final String k = _keys[_index];
    _index++;
    return k;
  }
}
