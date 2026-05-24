import 'dart:math';
import 'dart:typed_data';

/// Generates per-request idempotency keys used for the
/// `failover_dio_idempotency_key` HTTP header.
abstract class IdempotencyKeyGenerator {
  /// Returns a new key. Implementations must be safe for concurrent use.
  String generate();
}

/// Default generator: 128 bits of cryptographic randomness, hex-encoded.
///
/// Pass a non-secure [Random] only in tests; production should rely on
/// `Random.secure()`.
class SecureRandomIdempotencyKeyGenerator implements IdempotencyKeyGenerator {
  /// Creates a generator using [random] (default `Random.secure()`).
  ///
  /// [byteLength] controls entropy; 16 bytes = 128 bits is the default and
  /// recommended.
  SecureRandomIdempotencyKeyGenerator({
    Random? random,
    this.byteLength = 16,
  }) : _random = random ?? Random.secure();

  final Random _random;

  /// Number of random bytes per key (default 16 = 128 bits).
  final int byteLength;

  static const String _hexAlphabet = '0123456789abcdef';

  @override
  String generate() {
    final Uint8List bytes = Uint8List(byteLength);
    for (int i = 0; i < byteLength; i++) {
      bytes[i] = _random.nextInt(256);
    }
    final StringBuffer out = StringBuffer();
    for (final int b in bytes) {
      out
        ..write(_hexAlphabet[(b >> 4) & 0x0F])
        ..write(_hexAlphabet[b & 0x0F]);
    }
    return out.toString();
  }
}
