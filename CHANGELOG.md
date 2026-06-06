# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `FailoverOptions.singleIpFastPath` (default `true`) and matching `HostOverride.singleIpFastPath`. When DNS resolves to exactly one usable IP for a host, the request is issued through the pinned adapter for that IP with **no** body buffering, **no** `failover_dio_*` headers, **no** `FailoverEvent`s, and **no** `Response.extra` metadata — wire-indistinguishable from stock Dio. Set to `false` to keep the full instrumentation regardless of IP cardinality.
- **Happy Eyeballs parallel TCP-connect latency racing** replaces sequential per-IP probing. All resolved IPs are measured concurrently; each completion immediately reorders the cache; HTTP proceeds after the first connect finishes without waiting for slower peers. `LatencyProbed.completionOrder` reports finish order (0 = first arrival).

### Changed
- **Breaking:** Multi-IP HTTP failover now uses **parallel TCP Happy Eyeballs connect racing** instead of staggered sequential attempts. Each wave sends up to `maxIpAttempts` concurrent SYNs; the first SYN+ACK wins; losers are RST-cancelled; exactly one HTTP exchange runs on the winner. Waves continue until success or DNS roster exhaustion.
- `maxIpAttempts` now means **parallel connect fan-out per wave** (not a sequential attempt cap).
- Request-time connect races populate the latency cache; the pre-HTTP `ProbeScheduler.raceHappyEyeballs` hot-path call was removed (`ProbeScheduler` remains for warmup).
- Removed unused `FailoverOptions.maxConcurrentAttemptsPerRequest` (folded into `maxIpAttempts`).
- Added `AttemptOutcome.abortedByConnectRace` for TCP peers cancelled after a parallel connect winner.

## [0.1.0] - 2026-05-24

### Added
- Initial release of `failover_dio`.
- Drop-in `Dio` replacement (`import 'package:failover_dio/failover_dio.dart'`) with full API parity.
- DNS-aware IP fail-over with staggered in-flight retries; original response always wins if it completes before a fallback.
- Configurable max IP attempts ceiling (default 3).
- Method-specific connect timeouts (default 3s for GET/HEAD, 8s for others).
- Overall request deadline (default 30s).
- Hard-error fast path for TCP RST/ECONNREFUSED/TLS failures (no stagger wait).
- TTL-driven host IP cache (process-wide singleton by default, opt-out via `useSharedCache: false`).
- LRU eviction (default 256 hosts) with bounded memory.
- Negative DNS caching.
- Stale-while-revalidate DNS refresh.
- Background TCP-connect latency probe with deduplication and concurrency budget.
- Exponential cooldown circuit breaker for failing IPs.
- Per-request fail-over headers: `failover_dio_idempotency_key` and `failover_dio_previous_ip`.
- CancelToken parity with stock Dio.
- Pluggable interfaces: `DnsResolver`, `LatencyProbe`, `Clock`, `IdempotencyKeyGenerator`, `FailoverLogger`.
- Per-host configuration overrides via `FailoverOptions.perHost`.
- Hostname normalization (case-insensitive, trailing dot, IPv6 literals).
- SSRF protection via address validator (filter loopback/link-local/private as configured).
- Typed `FailoverEvent` stream and `Response.extra` metadata.
- Cache inspector (`FailoverDio.inspectCache()`).
- Build-mode awareness: asserts and verbose logging in debug, timeline events and metrics in profile, all stripped in release.
- `--dart-define=FAILOVER_DIO_VERBOSE=true` and `FAILOVER_DIO_TIMELINE=true` opt-ins.
- Warmup API (`FailoverDio.warmup`).
- Test fixtures library at `package:failover_dio/failover_dio_testing.dart`.
- Web fallback to stock Dio (no failover on web).

### Known limitations
- **HTTPS targets bypass to stock Dio (no per-IP failover) in v0.1.** `dart:io`'s
  `HttpClient.connectionFactory` does not auto-upgrade returned sockets to TLS,
  and `ConnectionTask` is a `final` class with invariant generics, so a
  `SecureSocket`-yielding `ConnectionTask<Socket>` cannot be constructed. HTTPS
  failover is scheduled for v0.2 via a custom HTTP/1.1 transport that performs
  the TLS handshake directly with proper SNI on the URL host.

### Documented as not yet implemented (Phase 2+)
- HTTPS per-IP failover (custom HTTP/1.1 transport).
- Native DoH resolver (interface ready; default uses platform resolver).
- Certificate pinning (interface and option present; enforcement is a stub for v0.1).
- DNSSEC validation.
- DevTools extension package.
