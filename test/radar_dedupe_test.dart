import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/radar/scanner.dart';

/// Radar listed the same address twice, with identical latency and jitter,
/// two rows apart. Seen on a live scan: 104.19.114.135:2053 and :8443 each
/// appeared twice in a 124-row result list.
///
/// The random sample is unique, and the addresses a source names outright were
/// appended to it without checking, so anything in both was scanned twice and
/// reported twice.
void main() {
  test('an address that is both sampled and named is scanned once', () {
    expect(
      NovaScanner.mergeCandidates(
        <String>['104.19.114.135', '1.1.1.1'],
        <String>['104.19.114.135', '8.8.8.8'],
      ),
      <String>['104.19.114.135', '1.1.1.1', '8.8.8.8'],
    );
  });

  test('a named list that repeats itself is collapsed too', () {
    expect(
      NovaScanner.mergeCandidates(
          const <String>[], <String>['1.1.1.1', '1.1.1.1', '1.1.1.1']),
      <String>['1.1.1.1'],
    );
  });

  test('the sample order is kept, so the scan is not reordered', () {
    expect(
      NovaScanner.mergeCandidates(
          <String>['a', 'b', 'c'], <String>['d']),
      <String>['a', 'b', 'c', 'd'],
    );
  });
}
