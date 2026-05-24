import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('BodyReplayPolicy', () {
    test('bufferUpTo mode', () {
      const p = BodyReplayPolicy.bufferUpTo(1024);
      expect(p.mode, BodyReplayMode.bufferUpTo);
      expect(p.maxBufferBytes, 1024);
    });

    test('refuse mode', () {
      const p = BodyReplayPolicy.refuse();
      expect(p.mode, BodyReplayMode.refuse);
    });

    test('noFailoverForStreamingBodies mode', () {
      const p = BodyReplayPolicy.noFailoverForStreamingBodies();
      expect(p.mode, BodyReplayMode.noFailover);
    });
  });
}
