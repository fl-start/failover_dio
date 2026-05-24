import 'dart:math';

import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('SecureRandomIdempotencyKeyGenerator', () {
    test('produces 32-char hex by default', () {
      final gen = SecureRandomIdempotencyKeyGenerator(random: Random(0));
      final k = gen.generate();
      expect(k.length, 32);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(k), isTrue);
    });

    test('different keys on each call', () {
      final gen = SecureRandomIdempotencyKeyGenerator(random: Random(0));
      expect(gen.generate(), isNot(gen.generate()));
    });

    test('configurable byte length', () {
      final gen = SecureRandomIdempotencyKeyGenerator(
        random: Random(0),
        byteLength: 8,
      );
      expect(gen.generate().length, 16);
    });
  });
}
