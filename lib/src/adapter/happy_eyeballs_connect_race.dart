import 'dart:async';
import 'dart:io';

import '../cache/ip_entry.dart';

/// Winner of a parallel TCP connect race (first SYN+ACK).
class ConnectRaceWinner {
  /// Creates a winner.
  const ConnectRaceWinner({
    required this.entry,
    required this.connectMs,
  });

  /// The IP entry whose TCP handshake completed first.
  final IpEntry entry;

  /// Wall-clock TCP connect time in milliseconds.
  final int connectMs;
}

/// Parallel TCP Happy Eyeballs connect racing for request-time gateway
/// selection.
///
/// Every candidate IP receives a concurrent `Socket.startConnect`. Each
/// completion invokes [onConnectComplete] immediately so the host cache can
/// reorder without waiting for slower peers. The first successful SYN+ACK
/// wins; all other in-flight [ConnectionTask]s are cancelled (RST). The
/// probe socket is closed immediately after timing — HTTP uses a fresh
/// connection on the winner IP.
class HappyEyeballsConnectRace {
  /// Creates a connect racer.
  const HappyEyeballsConnectRace();

  /// Races TCP connects across [entries] on [port].
  ///
  /// Returns the first successful connect, or `null` when every peer in the
  /// batch fails or times out within [timeout]. The returned future
  /// completes as soon as a winner is known or the batch is exhausted;
  /// slower background completions may still invoke [onConnectComplete]
  /// after the future completes.
  ///
  /// When [abortFuture] completes, all in-flight tasks are cancelled and
  /// the returned future completes with a [SocketException].
  Future<ConnectRaceWinner?> race({
    required List<IpEntry> entries,
    required int port,
    required Duration timeout,
    required void Function(IpEntry entry, int? latencyMs, int completionOrder)
        onConnectComplete,
    Future<void>? abortFuture,
  }) async {
    if (entries.isEmpty) return null;

    final Completer<ConnectRaceWinner?> done = Completer<ConnectRaceWinner?>();
    final List<ConnectionTask<Socket>> tasks = <ConnectionTask<Socket>>[];
    int pending = entries.length;
    int completionOrder = 0;
    ConnectRaceWinner? winner;
    bool aborted = false;

    void cancelLosers(ConnectionTask<Socket>? except) {
      for (final ConnectionTask<Socket> t in tasks) {
        if (identical(t, except)) continue;
        try {
          t.cancel();
        } catch (_) {
          // Best-effort RST on losing peers.
        }
      }
    }

    void finishWithWinner(ConnectRaceWinner w, ConnectionTask<Socket> task) {
      if (done.isCompleted) return;
      winner = w;
      cancelLosers(task);
      done.complete(w);
    }

    void finishAllFailed() {
      if (done.isCompleted) return;
      if (winner != null) return;
      if (pending > 0) return;
      done.complete(null);
    }

    void recordCompletion(IpEntry entry, int? latencyMs) {
      final int order = completionOrder++;
      onConnectComplete(entry, latencyMs, order);
    }

    StreamSubscription<void>? abortSub;
    if (abortFuture != null) {
      abortSub = abortFuture.asStream().listen((_) {
        if (aborted) return;
        aborted = true;
        cancelLosers(null);
        if (!done.isCompleted) {
          done.completeError(
            const SocketException('Connect race aborted'),
          );
        }
      });
    }

    for (final IpEntry entry in entries) {
      unawaited(_connectOne(
        entry: entry,
        port: port,
        timeout: timeout,
        tasks: tasks,
        onSuccess: (ConnectionTask<Socket> task, int ms) {
          recordCompletion(entry, ms);
          if (winner == null && !aborted) {
            finishWithWinner(
              ConnectRaceWinner(entry: entry, connectMs: ms),
              task,
            );
          }
        },
        onFailure: (int? ms) {
          recordCompletion(entry, ms);
          if (done.isCompleted) return;
          pending--;
          finishAllFailed();
        },
      ));
    }

    try {
      return await done.future;
    } finally {
      await abortSub?.cancel();
    }
  }

  Future<void> _connectOne({
    required IpEntry entry,
    required int port,
    required Duration timeout,
    required List<ConnectionTask<Socket>> tasks,
    required void Function(ConnectionTask<Socket> task, int ms) onSuccess,
    required void Function(int? ms) onFailure,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    ConnectionTask<Socket>? task;
    try {
      task = await Socket.startConnect(entry.address, port);
      tasks.add(task);
      final Socket socket = await task.socket.timeout(timeout);
      sw.stop();
      final int ms = sw.elapsedMilliseconds;
      try {
        await socket.close();
      } catch (_) {
        // Selection-only socket; close before HTTP opens a fresh connection.
      }
      onSuccess(task, ms);
    } on TimeoutException {
      sw.stop();
      task?.cancel();
      onFailure(sw.elapsedMilliseconds);
    } on SocketException {
      sw.stop();
      onFailure(sw.isRunning ? sw.elapsedMilliseconds : null);
    } catch (_) {
      sw.stop();
      task?.cancel();
      onFailure(sw.isRunning ? sw.elapsedMilliseconds : null);
    }
  }
}
