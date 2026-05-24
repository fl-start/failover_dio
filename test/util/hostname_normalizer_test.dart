import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('HostnameNormalizer', () {
    test('lowercases', () {
      expect(HostnameNormalizer.normalize('API.Example.COM'), 'api.example.com');
    });

    test('strips trailing dots', () {
      expect(HostnameNormalizer.normalize('api.example.com.'), 'api.example.com');
      expect(HostnameNormalizer.normalize('api.example.com..'), 'api.example.com');
    });

    test('passes IPv6 bracket form through (lowercased)', () {
      expect(HostnameNormalizer.normalize('[::1]'), '[::1]');
    });

    test('empty stays empty', () {
      expect(HostnameNormalizer.normalize(''), '');
    });
  });
}
