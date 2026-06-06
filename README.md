# failover_dio

> **Client-side DNS fail-over for the API-Gateway pattern.** Built for fleets of mostly-stateless gateway servers — sharding/load-balancing proxies, BFFs, edge routers — that sit in front of stateful backends (databases, queues, session stores) and publish every gateway's IP as an `A` / `AAAA` record so clients can fail over without waiting for a load-balancer health check, a DNS TTL expiry, or a human.

A drop-in replacement for [`package:dio`](https://pub.dev/packages/dio) that adds DNS-aware IP fail-over, latency-based routing, TTL-driven cache refresh, and observability headers — **with no caller-side code changes**.

Switch to `failover_dio` by changing one import. Switch back by changing it back.

```diff
-import 'package:dio/dio.dart';
+import 'package:failover_dio/failover_dio.dart';
```

---

## Who this is for

`failover_dio` is purpose-built for the **API-Gateway pattern**:

```text
                 ┌──────────────────┐
                 │  api.example.com │  ← single hostname,
                 │   A: 203.0.113.10│    many A/AAAA records,
                 │   A: 203.0.113.11│    each pointing at a
                 │   A: 203.0.113.12│    stateless gateway pod
                 │   A: 203.0.113.13│
                 └─────────┬────────┘
                           │ HTTP/HTTPS
       ┌──────────┬────────┼────────┬──────────┐
       ▼          ▼        ▼        ▼          ▼
  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
  │gateway │ │gateway │ │gateway │ │gateway │ │gateway │   ← stateless,
  │  pod 1 │ │  pod 2 │ │  pod 3 │ │  pod 4 │ │  pod 5 │     interchangeable,
  └────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘     own sharding /
       │         │          │           │         │          load-balancing
       └─────────┴─────┬────┴───────────┴─────────┘          logic to backends
                       ▼
              ┌────────────────────┐
              │ Stateful backends  │
              │  (DB, queue, cache,│
              │   identity, etc.)  │
              └────────────────────┘
```

In this architecture:

- **Gateway servers are mostly stateless and interchangeable.** Any pod can serve any request; the sharding / routing decision happens *inside* the gateway, not outside it.
- **Every healthy gateway's IP is published in DNS** as an `A` or `AAAA` record on a single hostname. There is no single load-balancer VIP to fail over from — the DNS record set *is* the fleet roster.
- **Clients are expected to fail over on their own.** When one gateway IP times out, hangs, or returns a connection-level error, the client should immediately try the next IP rather than wait for DNS TTL expiry, BGP convergence, or operator intervention.
- **The first successful response wins.** Stateful operations idempotently dedupe via a stable per-request key so retries during fail-over don't double-spend, double-charge, or double-write.

Stock Dio (and most HTTP clients) picks one IP per hostname and keeps using it until the OS resolver expires it. That's fine for a single-VIP setup; it leaves serious resilience on the table for a DNS-published gateway fleet. `failover_dio` is the missing client-side piece: every Dio request becomes a parallel TCP Happy Eyeballs wave over the gateway IPs, with latency-aware ordering, idempotency-key continuity, and structured observability — without changing a line of caller code.

> **Not the right fit if** your traffic terminates at a single VIP / cloud load-balancer that already does fleet-level health checking (ALB, GCLB, Cloud Front, Cloudflare). Stock Dio is enough there. `failover_dio` shines when *DNS itself* is your load balancer.

---

## Table of contents

- [Who this is for](#who-this-is-for)
- [Why](#why)
- [How it works](#how-it-works)
- [Platform support](#platform-support)
- [Installation](#installation)
- [Migration](#migration)
- [Reverting to stock Dio](#reverting-to-stock-dio)
- [Cancellation (CancelToken)](#cancellation-canceltoken)
- [Configuration](#configuration)
- [Per-host overrides](#per-host-overrides)
- [Single-IP fast path](#single-ip-fast-path-zero-overhead-drop-in-for-single-record-hosts)
- [Server-side integration (idempotency + observability headers)](#server-side-integration-idempotency--observability-headers)
- [Observability](#observability)
- [Robustness](#robustness)
- [Security](#security)
- [Build-mode awareness](#build-mode-awareness-debug--profile--release)
- [Testing](#testing)
- [Examples](#examples)
- [Comparison](#comparison)
- [FAQ](#faq)
- [Limitations](#limitations)
- [Versioning](#versioning)
- [License](#license)

---

## Why

In a DNS-as-load-balancer gateway fleet, **the client is the load balancer**. Stock Dio doesn't know that. It resolves the gateway hostname to a single IP, sends every request to that one pod until the OS DNS cache expires, and just keeps waiting when "its" pod is the one that's slow, draining, garbage-collecting, or partitioned away from the backend. Your other healthy gateway pods are sitting idle in the DNS record set with no client willing to talk to them.

`failover_dio` keeps the `dio.Dio` API exactly the same but transparently:

- Resolves every `A` and `AAAA` record for the gateway hostname (the full fleet roster).
- On each request wave, races up to **`maxIpAttempts` parallel TCP connects** (Happy Eyeballs) — first SYN+ACK wins, losers are cancelled (RST), and **exactly one** HTTP exchange runs on the winner. Every connect completion immediately updates the latency-sorted cache.
- If a wave produces no TCP winner, launches the next wave from remaining DNS entries until one succeeds or the roster is exhausted.
- Respects each record's TTL, refreshes lazily on access, and supports stale-while-revalidate so a brief authoritative-DNS outage doesn't take the client offline.
- Marks failing gateway IPs unavailable with exponential cooldown — a flapping pod gets temporarily evicted from the client's rotation without ever touching DNS.
- Injects `failover_dio_idempotency_key` (stable across attempts on the same logical request) and `failover_dio_previous_ip` so the gateway can dedupe at-least-once retries against its stateful backends.
- Caps parallel connect fan-out per wave at `maxIpAttempts` (default 3) and the overall request duration (default 30s).
- Exposes a typed `FailoverEvent` stream, per-request `Response.extra` metadata, and a cache inspector for SRE-grade observability.
- Falls through to a **zero-overhead path identical to stock Dio** whenever DNS returns only one IP (single-pod dev environments, blue/green cut-overs, manual pinning) — see [Single-IP fast path](#single-ip-fast-path-zero-overhead-drop-in-for-single-record-hosts).

---

## How it works

```text
caller ─▶ Dio (api unchanged) ─▶ FailoverHttpClientAdapter
                                       │
                                       ├─ HostIpCache (process-wide singleton)
                                       │   └─ TTL-aware DNS cache + LRU eviction
                                       │
                                       ├─ DnsResolver (pluggable: platform / DoH / custom)
                                       │
                                       ├─ ProbeScheduler (warmup-only TCP races)
                                       │
                                       └─ HappyEyeballsCoordinator (per request)
                                           ├─ buffers body per BodyReplayPolicy
                                           ├─ parallel TCP connect wave (maxIpAttempts)
                                           ├─ first SYN+ACK wins; RST on losers
                                           ├─ single HTTP exchange on winner
                                           └─ next wave if TCP or HTTP fails
```

### Parallel TCP Happy Eyeballs (per request wave)

When DNS returns more than one gateway IP, each request wave runs parallel TCP connects — **not** duplicate HTTP bodies:

```text
DNS resolve api.example.com → [IP₁, IP₂, IP₃, IP₄, IP₅]

Wave 1 (maxIpAttempts = 3):
  TCP SYN ──▶ IP₁  ────────────────▶ 180ms  (order=2) ──▶ cache reorder
  TCP SYN ──▶ IP₂  ──▶ 12ms  (order=0) ──▶ cache reorder  ◀── SYN+ACK winner
  TCP SYN ──▶ IP₃  ──────▶ 45ms  (order=1) ──▶ cache reorder
            IP₁, IP₃ cancelled (RST) after IP₂ wins
            single HTTP GET ──▶ IP₂ only

Wave 2 (only if wave 1 had no SYN+ACK or HTTP failed):
  TCP SYN ──▶ IP₄, IP₅ ...
```

Key properties:

- **Up to `maxIpAttempts` parallel SYNs per wave** — not one SYN per DNS record at once.
- **First SYN+ACK wins** — losers are cancelled via `ConnectionTask.cancel()` (RST).
- **Exactly one HTTP request** per logical call — safe for non-idempotent POST/PUT.
- **Each TCP completion updates cache sort order** immediately, including background completions after the winner is chosen.
- **Warmup API** (`FailoverDio.warmup`) still uses `ProbeScheduler` for probe-only races without HTTP.
- **Cold-path double connect**: on the first request (or after cache expiry), the winning IP is connected twice — once for the TCP race (socket closed immediately after timing) and again when HTTP opens a fresh connection via `connectionFactory`. Warm requests with fresh latency rankings skip the race entirely and incur only a single connect.

This is TCP connect time measurement, not ICMP ping — it works on every `dart:io` platform and approximates the real cost of reaching each gateway pod.

---

## Platform support

| Platform | Scheme | Behavior |
|---|---|---|
| Android, iOS, macOS, Linux, Windows (Flutter, Dart CLI) | `http://`  | **Full** failover, latency probing, cache, headers |
| Android, iOS, macOS, Linux, Windows (Flutter, Dart CLI) | `https://` | **Falls back to stock Dio in v0.1** (see [Limitations](#limitations)); HTTPS failover lands in v0.2 |
| Web (`dart.library.html`)                                | any        | **Falls back to stock Dio** because browsers don't expose DNS, SNI override, or TCP-level control |

Platform/web fallback is transparent: the same import works everywhere. On web — and on HTTPS hosts in v0.1 — failover features are no-ops and your requests behave exactly like stock Dio.

---

## Installation

`failover_dio` is published to GitHub for now; pub.dev is planned. Add it to your `pubspec.yaml`:

```yaml
dependencies:
  failover_dio:
    git:
      url: https://github.com/fl-start/failover_dio.git
      ref: main   # or a release tag like v0.1.0
```

Then run:

```bash
flutter pub get   # or: dart pub get
```

---

## Migration

The only required change is the import. Every existing Dio API works unchanged.

```diff
-import 'package:dio/dio.dart';
+import 'package:failover_dio/failover_dio.dart';

 final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
 final res = await dio.get('/users', cancelToken: cancelToken);
```

Notes:

- The `Dio` constructor takes `options` and `failoverOptions` as named parameters. If your existing code passes `BaseOptions` as a positional argument, change it to `Dio(options: BaseOptions(...))`. This is the only source-incompatible change vs stock Dio.
- All other classes (`BaseOptions`, `RequestOptions`, `Response`, `Options`, `Interceptors`, `FormData`, `MultipartFile`, `CancelToken`, `DioException`, `DioExceptionType`, ...) are re-exported from `package:failover_dio/failover_dio.dart` so you don't need to change anything else.

---

## Reverting to stock Dio

Change the import back:

```diff
-import 'package:failover_dio/failover_dio.dart';
+import 'package:dio/dio.dart';
```

If you used the named-parameter form `Dio(options: ...)`, revert to positional `Dio(BaseOptions(...))`. That's it.

---

## Cancellation (CancelToken)

`failover_dio` re-exports `CancelToken` from `package:dio` unchanged, and preserves **identical cancellation semantics**.

```dart
final cancelToken = CancelToken();
dio.get('/slow', cancelToken: cancelToken).catchError((e) {
  if (CancelToken.isCancel(e)) {
    // user cancelled
  }
});
cancelToken.cancel('user');
```

| Behavior | Stock Dio | failover_dio |
|---|---|---|
| `cancelToken.cancel()` aborts the request | yes | yes (aborts **all** in-flight IP attempts) |
| `CancelToken.isCancel(error)` works | yes | yes (same static helper) |
| Request started with an already-cancelled token | fails immediately | fails immediately (no DNS, no socket) |
| Shared token cancels multiple requests | yes | yes |
| Internal fail-over abort (loser of an IP race) | n/a | **does not** surface as `DioExceptionType.cancel` |

---

## Configuration

`FailoverOptions` is a type-safe configuration object passed to the `Dio` / `FailoverDio` constructor. Every field has a sensible default; only set what you want to change. `copyWith` is provided for ergonomic overrides.

```dart
final dio = Dio(
  options: BaseOptions(baseUrl: 'https://api.example.com'),
  failoverOptions: FailoverOptions(
    overallTimeout: const Duration(seconds: 30),
    probeTimeout: const Duration(seconds: 2),
    maxIpAttempts: 3,
    useSharedCache: true,
    maxCachedHosts: 256,
    enableLatencyProbe: true,
    enableFailoverHeaders: true,
    bodyReplay: const BodyReplayPolicy.bufferUpTo(1024 * 1024),
    onEvent: FailoverDio.eventSink,
  ),
);
```

### Full reference

| Group | Field | Default | Description |
|---|---|---|---|
| Timeouts | `overallTimeout` | 30s | Hard ceiling for the whole logical request (connect race + HTTP) |
| | `probeTimeout` | 2s | Per-IP TCP connect race timeout (Happy Eyeballs cold path) |
| | `dnsLookupTimeout` | 5s | DNS resolver timeout |
| | `negativeCacheTtl` | 15s | Cache negative lookups for this long |
| Attempts | `maxIpAttempts` | 3 | Parallel TCP SYN fan-out per wave |
| | `unavailableCooldownInitial` | 60s | Initial cooldown on IP failure |
| | `unavailableCooldownMax` | 15m | Max cooldown after repeated failures |
| | `unavailableCooldownFactor` | 2.0 | Exponential multiplier per consecutive failure |
| Cache | `useSharedCache` | `true` | Use the process-wide singleton |
| | `maxCachedHosts` | 256 | LRU cap |
| | `staleWhileRevalidate` | `true` | Serve stale cache while refreshing |
| | `maxStaleAge` | 60s | Hard cap on staleness |
| Probing | `enableLatencyProbe` | `true` | Run Happy Eyeballs parallel TCP races when A count > 1 |
| | `probeFreshness` | 30s | Skip re-probes within this window |
| | `maxConcurrentProbes` | 4 | Reserved (all eligible IPs per host race in parallel) |
| Headers | `enableFailoverHeaders` | `true` | Inject `failover_dio_*` headers |
| | `idempotencyKeyGenerator` | `SecureRandomIdempotencyKeyGenerator()` | Source of idempotency keys |
| Fast path | `singleIpFastPath` | `true` | When DNS returns one IP, behave exactly like stock Dio (see below) |
| Body | `bodyReplay` | `bufferUpTo(1MB)` | Policy for streaming bodies |
| DNS | `dnsResolver` | `PlatformDnsResolver()` | Pluggable resolver |
| | `requireDnssec` | `false` | DNSSEC enforcement (reserved) |
| | `allowPrivateAddresses` | `true` | Reject RFC1918 if set `false` |
| | `dnsLocalHosts` | `{'localhost'}` | Hosts that may resolve to loopback/private |
| Security | `certificatePinner` | empty | SPKI SHA-256 pins (enforcement is a v0.1 stub) |
| Observability | `onEvent` | `null` | Per-event callback |
| | `logger` | depends on build mode | Pluggable `FailoverLogger` |
| | `debugSlowRequestThreshold` | 2s | Slow-request warning threshold (debug) |
| | `profileSlowRequestThreshold` | 5s | Slow-request warning threshold (profile) |
| | `enableTimelineEvents` | depends on build mode | Emit `dart:developer` Timeline events |
| | `enableMisconfigWarnings` | depends on build mode | Log warnings at construction |
| Per-host | `perHost` | empty | `Map<String, HostOverride>` overlays |
| Extension | `clock` | `SystemClock()` | Pluggable wall clock |
| | `random` | `Random.secure()` | Source of randomness |

### Per-request overrides via `Options.extra`

For one-off tweaks without constructing a new `FailoverOptions`:

| Key | Type | Effect |
|---|---|---|
| `failover_dio:skip` | `bool` | Bypass fail-over entirely for this request |
| `failover_dio:max_ip_attempts` | `int` | Override `maxIpAttempts` for this request |
| `failover_dio:overall_timeout` | `Duration` | Override `overallTimeout` for this request |

The TCP connect race is bounded by `probeTimeout`. Your own Dio `Options.connectTimeout` and `Options.receiveTimeout` still apply to the HTTP exchange on the winning IP. Per-request `failover_dio:overall_timeout` overrides the library's overall deadline.

---

## Per-host overrides

Different services often need different SLAs. `HostOverride` lets you tune any field for specific hostnames; unset fields inherit the global value.

```dart
final dio = Dio(
  failoverOptions: FailoverOptions(
    overallTimeout: const Duration(seconds: 30),
    perHost: const <String, HostOverride>{
      'api.internal.example.com': HostOverride(
        overallTimeout: Duration(seconds: 5),
        maxIpAttempts: 5,
        allowPrivateAddresses: true,
      ),
      'cdn.example.com': HostOverride(enableLatencyProbe: false),
    },
  ),
);
```

Lookups are case-insensitive and respect hostname normalization (trailing dot stripped).

---

## Single-IP fast path (zero-overhead drop-in for single-record hosts)

If DNS resolves a host to **exactly one** usable IP, there is nothing to fail over to. `failover_dio` detects this and short-circuits the entire failover machinery — the request is sent through the pinned adapter for that one IP with **identical wire behavior to stock Dio**:

| Concern | Single-IP fast path | Multi-IP path |
|---|---|---|
| Request body buffering | **none** (streamed straight through) | buffered per `BodyReplayPolicy` |
| `failover_dio_idempotency_key` header | **not sent** | sent (stable across attempts) |
| `failover_dio_previous_ip` header | **not sent** | sent on fallback attempts |
| `FailoverEvent`s (`AttemptStarted`, `AttemptSucceeded`, ...) | **not emitted** | emitted |
| `Response.extra` metadata (`winningIp`, `idempotencyKey`, `totalMs`, `attempts`) | **not populated** | populated |
| Per-request `Stopwatch` / `Completer` / `Timer` allocations | **none** | allocated |
| Happy Eyeballs TCP races | skipped (always — needs ≥2 IPs) | parallel; HTTP after first arrival |
| DNS lookups | **one** (our resolver, cached after first call) | one (our resolver, cached after first call) |

Cache-layer events such as `HostResolved`, `CacheRefreshed`, `IpMarkedUnavailable`, and `CacheEvicted` still fire because those describe the cache, not the request.

If you want the full instrumentation (consistent server-side metrics, idempotency keys for at-least-once semantics, `Response.extra` telemetry) even for single-IP hosts, opt out:

```dart
FailoverOptions(singleIpFastPath: false)
```

Or per-host:

```dart
FailoverOptions(
  perHost: <String, HostOverride>{
    'metrics.example.com': HostOverride(singleIpFastPath: false),
  },
)
```

---

## Server-side integration (idempotency + observability headers)

Every outbound HTTP attempt managed by the adapter carries these headers (unless `enableFailoverHeaders` is `false`):

| Header | Attempt 1 | Fallback attempts |
|---|---|---|
| `failover_dio_idempotency_key` | present (random 32-char hex) | present (same value) |
| `failover_dio_previous_ip` | **absent** | present (IP of the previous timed-out attempt) |

**Server contract:**

- No `failover_dio_previous_ip` → first attempt for this idempotency key.
- `failover_dio_previous_ip` present → this is a fail-over retry; correlate via `failover_dio_idempotency_key` and deduplicate (e.g. write through to the same DB row or return the cached response).

The idempotency key is stable across all attempts of one logical request, so even if your client and server cross paths during a fail-over, the server can safely dedupe.

---

## Observability

### Typed event stream

```dart
FailoverDio.events.listen((FailoverEvent e) {
  switch (e) {
    case HostResolved():        ...;
    case AttemptStarted():      ...;
    case AttemptSucceeded():    ...;
    case AttemptFailed():       ...;
    case AttemptAborted():      ...;
    case LatencyProbed():       ...;
    case IpMarkedUnavailable(): ...;
    case CacheRefreshed():      ...;
    case CacheEvicted():        ...;
    case RequestExhausted():    ...;
  }
});

final dio = Dio(
  failoverOptions: FailoverOptions(onEvent: FailoverDio.eventSink),
);
```

### Per-request metadata

Every successful `Response` carries:

| `Response.extra[…]` | Type | Meaning |
|---|---|---|
| `FailoverExtraKeys.winningIp` | `String` | IP that produced the response |
| `FailoverExtraKeys.attempts` | `List<AttemptRecord>` | Per-attempt timing/outcome |
| `FailoverExtraKeys.idempotencyKey` | `String` | Key sent on the wire |
| `FailoverExtraKeys.totalMs` | `int` | Total ms from fetch entry to response |

`DioException.requestOptions.extra` carries the same keys on failure (with all attempts listed).

### Cache inspector

```dart
final snap = FailoverDio.inspectCache();
print(snap); // pretty-printed for debugging
```

### Pluggable logger

```dart
class MyLogger implements FailoverLogger {
  void log(FailoverLogLevel level, String message, {Object? fields}) { ... }
}

FailoverOptions(logger: MyLogger());
```

The default logger is `NoOpFailoverLogger` in release and `ConsoleFailoverLogger` in debug/profile, both of which can be overridden at any time.

---

## Robustness

- **Single-flight DNS coalescing** — concurrent first requests to the same cold host share one DNS lookup.
- **Hard-error fast path** — TCP RST/ECONNREFUSED/TLS errors in a wave advance to the next wave without waiting for slow peers.
- **Overall request deadline** — bounds the total time a logical request can take.
- **DNS answer validation** — rejects `0.0.0.0`, link-local, multicast/broadcast, and (configurably) loopback or private addresses for public hosts (SSRF defense).
- **Bounded LRU cache** — caps memory at `maxCachedHosts` (default 256); pending probes for evicted hosts are cancelled.
- **Negative DNS caching** — short-window cache for failed lookups to avoid hammering the resolver.
- **Body replay policy** — buffers streaming bodies up to a configurable limit; can `refuse()` or fall back to `noFailoverForStreamingBodies()`.
- **Stale-while-revalidate** — serves cached entries on TTL boundary while refreshing in the background.
- **Exponential cooldown** — `unavailableCooldownInitial × factor^failures`, clamped to `unavailableCooldownMax`; reset on success.
- **Clock-skew safe TTLs** — comparisons use monotonic time, not `DateTime.now()`.

---

## Security

- **SSRF defense** — `allowPrivateAddresses: false` rejects RFC1918 / ULA addresses for public hosts; `dnsLocalHosts` whitelists exceptions.
- **Certificate pinning** — `CertificatePinner` stores SPKI SHA-256 pins per host (configuration in v0.1; enforcement landing in a follow-up).
- **DoH resolver** — pluggable `DnsResolver` interface; v0.1 ships a `DohResolver` stub and the abstract interface so users can plug in their own DoH client (`dns_client`, custom HTTPS, etc.).
- **DNSSEC** — `requireDnssec` flag reserved for the upcoming DoH resolver.

---

## Build-mode awareness (debug / profile / release)

The library detects Dart build mode at compile time (no Flutter dependency) and activates extra capabilities for non-release builds. All extras are **stripped or no-op in release** so they cost zero in production.

| Capability | Debug | Profile | Release |
|---|---|---|---|
| `assert()` invariants | yes | no (Dart strips) | no |
| Default logger if none supplied | `ConsoleFailoverLogger` @ debug | `ConsoleFailoverLogger` @ warn | `NoOpFailoverLogger` |
| `dart:developer Timeline` events | yes | yes | no |
| Misconfiguration warnings at construction | yes | yes | no |
| Slow-request warnings | yes (default 2s) | yes (default 5s) | no |
| Per-host metrics counters | yes | yes | no (`NoOpFailoverMetrics`) |
| Auto-summary on `FailoverExhaustedError` | full | compact | message-only |

### `--dart-define` opt-ins

For production audits without rebuilding the package:

```bash
flutter run --release --dart-define=FAILOVER_DIO_VERBOSE=true
dart run --define=FAILOVER_DIO_TIMELINE=true bin/main.dart
```

| Flag | Effect |
|---|---|
| `FAILOVER_DIO_VERBOSE=true` | Re-enable `ConsoleFailoverLogger` in release |
| `FAILOVER_DIO_TIMELINE=true` | Re-enable Timeline events in release |

---

## Testing

Import the dedicated fixtures library from your tests only:

```dart
import 'package:failover_dio/failover_dio_testing.dart';

final resolver = FakeDnsResolver({
  'api.example.com': ['10.0.0.1', '10.0.0.2'],
});

final dio = FailoverDio(
  options: BaseOptions(baseUrl: 'http://api.example.com:8080'),
  failoverOptions: FailoverOptions(
    dnsResolver: resolver,
    useSharedCache: false,             // isolate from other tests
    dnsLocalHosts: {'api.example.com'},// allow loopback for the fake IPs
    enableMisconfigWarnings: false,
  ),
);
```

Available fixtures:

- `FakeDnsResolver(responses, {ttl})`
- `FakeLatencyProbe(latencies)`
- `FakeClock(initial)` with `advance(Duration)`
- `FakeIdempotencyKeyGenerator(keys)`

Test helpers:

- `FailoverDio.clearHostCache([host])` — wipe singleton between tests
- `FailoverDio.disposeSharedCache()` — full teardown
- `FailoverDio.inspectCache()` — assert on cache state

---

## Examples

Runnable scripts live under `example/`:

| File | Purpose |
|---|---|
| `simple_get.dart` | Drop-in usage, prints Response.extra failover metadata |
| `post_with_replay.dart` | POST request with body buffering for safe replay |
| `cancellation.dart` | `CancelToken` parity with stock Dio |
| `warmup.dart` | Pre-resolve hosts at app launch |
| `cache_inspector.dart` | Dump the live cache snapshot |
| `events_listener.dart` | Subscribe to the typed event stream |
| `custom_resolver_doh.dart` | Plug in a custom `DnsResolver` |
| `per_host_overrides.dart` | Different timeouts/probing per host |

Run any of them with:

```bash
dart run example/simple_get.dart
```

---

## Comparison

| | stock Dio | `native_dio_adapter` | DIY interceptor retry | **failover_dio** |
|---|---|---|---|---|
| Drop-in API | yes | yes | yes | yes |
| Multiple A/AAAA records used | no | partial (engine-internal) | hard to do correctly | **yes (explicit)** |
| Happy Eyeballs TCP latency racing | no | no | no | **yes** |
| Staggered in-flight fail-over | no | no | usually sequential | **yes (original wins late)** |
| Per-method timeouts | no | no | yes | **yes** |
| Idempotency / observability headers | no | no | manual | **yes (automatic)** |
| TTL-driven DNS cache | no | partial (OS) | no | **yes (explicit + lazy refresh)** |
| Shared cache across `Dio` instances | n/a | n/a | n/a | **yes (process-wide)** |
| HTTP/2 / HTTP/3 | no | yes | no | no (uses `dart:io`) |

`native_dio_adapter` is great for HTTP/2 and platform-native networking, but does not expose per-request IP pinning or SNI override, so true application-controlled fail-over is not implementable on top of it. The two libraries are **mutually exclusive**: setting `dio.httpClientAdapter = NativeAdapter()` disables fail-over.

---

## FAQ

**Q: If I close my Dio and create a new one, will probes run again?**
A: No, as long as TTL hasn't expired and `useSharedCache` is `true` (the default). The new `Dio` hits the shared cache and skips DNS + probing. If `useSharedCache: false`, each new instance starts cold.

**Q: How does HTTPS work when you connect to a literal IP?**
A: The library uses `HttpClient.connectionFactory` to redirect the TCP connect to the chosen IP while keeping the URL host unchanged. dart:io then uses the original hostname for SNI and certificate validation. Your TLS cert validates correctly.

**Q: What happens to my POST body when the first IP times out?**
A: The body is buffered once into memory (up to `bodyReplay.maxBufferBytes`, default 1MB) and a fresh stream is replayed on each attempt. Bodies larger than the limit either downgrade to single-attempt mode (default) or throw `StateError` if you choose `BodyReplayPolicy.refuse()`.

**Q: Does the library inject headers when running on web?**
A: No. The web build falls back to stock Dio, which has no concept of per-attempt headers because there's only ever one attempt.

**Q: Can a server tell the difference between the first attempt and a fail-over retry?**
A: Yes — by checking for the presence of `failover_dio_previous_ip`. Both attempts share the same `failover_dio_idempotency_key`, so the server can dedupe writes.

**Q: I want to opt out of fail-over for one specific request.**
A: Set `options: Options(extra: {FailoverExtraKeys.skip: true})` on that call. The request goes through stock-Dio behavior.

**Q: How do I make tests deterministic?**
A: Use `useSharedCache: false`, supply a `FakeDnsResolver` and `FakeClock` from `failover_dio_testing`, and call `FailoverDio.clearHostCache()` between tests.

---

## Limitations

- **HTTPS (v0.1)** falls back to stock Dio (no per-IP failover). `dart:io`'s `HttpClient.connectionFactory` does not auto-upgrade the returned socket to TLS, and `ConnectionTask` is a `final` class with invariant generics, so a `SecureSocket`-yielding `ConnectionTask<Socket>` cannot be constructed cleanly. v0.2 adds a custom HTTP/1.1 transport that performs the TLS handshake directly (preserving SNI on the URL host) to lift this restriction.
- **Web** uses stock Dio (no failover).
- **Replacing `httpClientAdapter`** after construction disables failover (same as any custom adapter).
- **Latency measurement uses parallel TCP connects** (Happy Eyeballs), not ICMP ping (ICMP isn't cross-platform in Dart).
- **HTTP/2 and HTTP/3** require `native_dio_adapter` and are incompatible with this library's per-IP pinning.
- **DoH resolver** is an abstract interface in v0.1; the built-in `DohResolver` is a stub. Bring your own resolver or wait for the built-in.
- **Certificate pin enforcement** is a stub in v0.1; the configuration API is final, and enforcement will land in a follow-up release without API changes.
- **DNS TTL via platform resolver** is approximated to `defaultTtl` (default 60s) because `InternetAddress.lookup` doesn't expose TTL. Plug in a custom `DnsResolver` if you need real per-record TTLs.

---

## Versioning

`failover_dio` follows [Semantic Versioning](https://semver.org/). Breaking changes are documented in [`CHANGELOG.md`](CHANGELOG.md).

When the library is published to pub.dev, you'll be able to depend on it with:

```yaml
dependencies:
  failover_dio: ^0.1.0
```

---

## License

[MIT](LICENSE)
