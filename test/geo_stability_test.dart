import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The exit country must not change while the exit does not.
///
/// Found on an iPhone: the dashboard read Sweden, then Lebanon, with the same
/// IP and the same connection. The cause is that the five geo providers
/// genuinely disagree. Asked about 77.110.96.201 they answered:
///
///   ipinfo.io    FI (Helsinki)
///   ifconfig.co  LB (Lebanon)
///   ipwho.is     SE (Stockholm)
///   api.ip.sb    SE (Stockholm)
///
/// The list is tried in order and the first to answer wins, so a rate-limit or
/// a timeout on one silently hands the answer to a provider with a different
/// opinion. Ordering alone cannot fix that; the country has to be pinned to the
/// IP. A source check, because the bug lives in which provider answers on a
/// given day and no unit test can hold that still.
void main() {
  final String source =
      File('lib/src/core/proxy/conn_info_controller.dart').readAsStringSync();

  test('the country is kept while the exit IP is unchanged', () {
    expect(source, contains('bool sameExit = geo.ip != null && geo.ip == _info.ip'));
    expect(source, contains('keep = sameExit && _info.countryCode != null'));
    expect(source, contains('keep ? _info.countryCode :'));
  });

  test('both paths that apply a geo reading go through the merge', () {
    // The periodic poll and the background fill both used to build a ConnInfo
    // by hand and take the provider's answer unconditionally.
    expect('_mergeGeo('.allMatches(source).length, greaterThanOrEqualTo(3),
        reason: 'declaration plus both call sites');
  });

  test('the two providers that agreed lead, and the outlier is last', () {
    // Match the URL literals, not the prose around them.
    final int ipwho = source.indexOf("'https://ipwho.is/'");
    final int ipsb = source.indexOf("'https://api.ip.sb/geoip'");
    final int ifconfig = source.indexOf("'https://ifconfig.co/json'");
    expect(ipwho, greaterThan(0));
    expect(ipsb, greaterThan(0));
    expect(ifconfig, greaterThan(0));
    expect(ipwho, lessThan(ifconfig));
    expect(ipsb, lessThan(ifconfig),
        reason: 'ifconfig.co is the one that called a Helsinki host Lebanon');
  });
}
