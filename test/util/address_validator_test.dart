import 'dart:io';

import 'package:failover_dio/failover_dio.dart';
import 'package:test/test.dart';

void main() {
  group('AddressValidator', () {
    test('rejects 0.0.0.0', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('0.0.0.0'), 'api.example.com'), isFalse);
    });

    test('rejects loopback for public hosts', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('127.0.0.1'), 'api.example.com'), isFalse);
    });

    test('allows loopback for localhost', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('127.0.0.1'), 'localhost'), isTrue);
    });

    test('allows loopback for *.local', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('127.0.0.1'), 'printer.local'), isTrue);
    });

    test('rejects link-local for public hosts', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('169.254.1.1'), 'api.example.com'), isFalse);
    });

    test('rejects private when allowPrivate=false', () {
      const v = AddressValidator(allowPrivate: false);
      expect(v.isAllowed(InternetAddress('10.0.0.5'), 'api.example.com'), isFalse);
      expect(v.isAllowed(InternetAddress('192.168.1.1'), 'api.example.com'), isFalse);
      expect(v.isAllowed(InternetAddress('172.16.0.1'), 'api.example.com'), isFalse);
    });

    test('allows private by default', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('10.0.0.5'), 'api.example.com'), isTrue);
    });

    test('rejects IPv6 unspecified', () {
      const v = AddressValidator();
      expect(v.isAllowed(InternetAddress('::'), 'api.example.com'), isFalse);
    });

    test('rejects IPv6 ULA fc00::/7 when private disallowed', () {
      const v = AddressValidator(allowPrivate: false);
      expect(
        v.isAllowed(InternetAddress('fd12:3456:789a::1'), 'api.example.com'),
        isFalse,
      );
    });
  });
}
