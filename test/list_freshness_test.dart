import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/list_freshness.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opening a server list used to re-download the subscription and re-test every
/// server, every single time, so switching tabs cost a few hundred dials and
/// threw away readings the user had just watched appear.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ListFreshness.load();
  });

  test('a list never synced on this device is due', () {
    expect(ListFreshness.isStale('never-seen'), isTrue);
  });

  test('a list synced just now is left alone', () async {
    await ListFreshness.markSynced('p1');
    expect(ListFreshness.isStale('p1'), isFalse);
    expect(ListFreshness.lastSync('p1'), isNotNull);
  });

  test('the window is twelve hours for a subscription of the user own', () {
    expect(ListFreshness.maxAge, const Duration(hours: 12));
    expect(ListFreshness.maxAgeFor('some-profile'), const Duration(hours: 12));
  });

  test('the free list gets an hour, because it is rebuilt hourly', () {
    expect(ListFreshness.maxAgeFor(kFreeProfileId), const Duration(hours: 1));
  });

  test('a free list synced two hours ago is due, a subscription is not',
      () async {
    final int twoHoursAgo = DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.listfresh.$kFreeProfileId': twoHoursAgo,
      'nova.listfresh.mine': twoHoursAgo,
    });
    await ListFreshness.load();
    expect(ListFreshness.isStale(kFreeProfileId), isTrue,
        reason: 'the upstream list has been rebuilt twice since');
    expect(ListFreshness.isStale('mine'), isFalse,
        reason: 'the regression this whole mechanism exists to prevent');
  });

  test('refresh puts the list back in the queue', () async {
    await ListFreshness.markSynced('p2');
    expect(ListFreshness.isStale('p2'), isFalse);
    await ListFreshness.invalidate('p2');
    expect(ListFreshness.isStale('p2'), isTrue,
        reason: 'the refresh button is how you ask for a sweep now');
  });

  test('it survives a restart, so a cold start does not re-sweep', () async {
    await ListFreshness.markSynced('p3');
    // A second load, as on the next launch, reads what was written.
    await ListFreshness.load();
    expect(ListFreshness.isStale('p3'), isFalse,
        reason: 'the old window lived in memory and every launch swept again');
  });

  test('profiles are tracked separately', () async {
    await ListFreshness.markSynced('a');
    expect(ListFreshness.isStale('a'), isFalse);
    expect(ListFreshness.isStale('b'), isTrue);
  });
}
