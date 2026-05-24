/// Policy controlling how request bodies are buffered to allow fail-over
/// across multiple IP attempts.
///
/// Stock Dio sends a body exactly once; fail-over requires re-sending it.
/// For buffered bodies (Map/JSON/String/bytes) this is free, but for
/// `Stream<List<int>>` or multipart file streams the source can only be read
/// once.
class BodyReplayPolicy {
  const BodyReplayPolicy._(this.mode, this.maxBufferBytes);

  /// What to do when the body is a stream.
  final BodyReplayMode mode;

  /// Maximum number of bytes to buffer when [mode] is
  /// [BodyReplayMode.bufferUpTo]. Ignored otherwise.
  final int maxBufferBytes;

  /// Buffer streaming bodies up to [maxBytes]. If the stream exceeds the
  /// limit, [mode] downgrades to single-attempt for that one request.
  const factory BodyReplayPolicy.bufferUpTo(int maxBytes) =
      _BufferUpTo;

  /// Throw `StateError` if the body is a stream (caller must materialize the
  /// body themselves).
  const factory BodyReplayPolicy.refuse() = _Refuse;

  /// Run the request as a single attempt (no fail-over) when the body is a
  /// non-replayable stream. Buffered bodies still get full fail-over.
  const factory BodyReplayPolicy.noFailoverForStreamingBodies() =
      _NoFailoverForStreams;
}

/// Replay mode for non-replayable bodies.
enum BodyReplayMode {
  /// Buffer the body up to a size limit; spill to single-attempt above it.
  bufferUpTo,

  /// Refuse the request with `StateError`.
  refuse,

  /// Disable fail-over for this request; perform a single attempt.
  noFailover,
}

class _BufferUpTo extends BodyReplayPolicy {
  const _BufferUpTo(int maxBytes)
      : super._(BodyReplayMode.bufferUpTo, maxBytes);
}

class _Refuse extends BodyReplayPolicy {
  const _Refuse() : super._(BodyReplayMode.refuse, 0);
}

class _NoFailoverForStreams extends BodyReplayPolicy {
  const _NoFailoverForStreams() : super._(BodyReplayMode.noFailover, 0);
}
