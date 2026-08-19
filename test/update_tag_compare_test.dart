import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/update/update_checker.dart';

/// After updating 1.12 -> 1.13 the dashboard kept showing "1.12 is available":
/// the remembered tag merely differed from the new build's tag. Newer must mean
/// a higher version number.
void main() {
  test('a lower remembered tag is not newer', () {
    expect(compareReleaseTags('v1.12.0-beta', 'v1.13.0-beta'), lessThan(0));
  });
  test('the same tag is not newer', () {
    expect(compareReleaseTags('v1.13.0-beta', 'v1.13.0-beta'), 0);
  });
  test('a higher tag is newer', () {
    expect(compareReleaseTags('v1.14.0-beta', 'v1.13.0-beta'), greaterThan(0));
    expect(compareReleaseTags('v2.0.0', 'v1.13.0-beta'), greaterThan(0));
    expect(compareReleaseTags('v1.13.1', 'v1.13.0-beta'), greaterThan(0));
  });
  test('garbage is never newer', () {
    expect(compareReleaseTags('latest', 'v1.13.0-beta'), 0);
  });
}
