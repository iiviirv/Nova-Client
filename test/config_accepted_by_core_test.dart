import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Runs the configs Nova actually emits through the real core's own validator.
///
/// Every unit test in this repo checks that the JSON has the keys we expect. Not
/// one of them could tell that the whole `dns` block used a format the core had
/// deprecated, because the format was internally consistent and the keys were
/// all present. The core refused it on sight, which nothing here ever asked it.
///
/// `sing-box check` parses the config and prints NOTHING when it is happy, so
/// an empty output is the assertion: any deprecation, any unknown field, any bad
/// combination shows up as text and fails the test.
///
/// `check` is not enough on its own, which this file learned the hard way. The
/// DNS migration passed every `check` and then failed at STARTUP with "detour to
/// an empty direct outbound makes no sense", because that rule is enforced when
/// services start rather than when the document is parsed. So the configs are
/// also actually RUN below.
String? _corePath() {
  final String name = Platform.isMacOS
      ? (Platform.version.contains('arm64')
          ? 'sing-box-macos-arm64'
          : 'sing-box-macos-amd64')
      : Platform.isLinux
          ? 'sing-box-linux-amd64'
          : Platform.isWindows
              ? 'sing-box-windows-amd64.exe'
              : '';
  if (name.isEmpty) return null;
  final File f = File('assets/bin/$name');
  return f.existsSync() ? f.path : null;
}

ProxyNode _vless() => parseShareLink(
      'vless://11111111-1111-1111-1111-111111111111@104.17.0.1:443'
      '?encryption=none&security=tls&sni=a.example.com&type=ws&host=a.example.com'
      '&path=%2F#node',
    )!;

ProxyNode _trojan() => parseShareLink(
      'trojan://pw@104.17.0.2:443?security=tls&sni=b.example.com&type=ws&path=%2F#t',
    )!;

void main() {
  final String? core = _corePath();

  Future<void> accepts(String label, Map<String, dynamic> cfg) async {
    final Directory tmp = await Directory.systemTemp.createTemp('nova-cfg');
    addTearDown(() => tmp.delete(recursive: true));
    // A bundled-rule-set config carries a path token the host swaps for the
    // real directory at start time; do the same here so the core can load them.
    for (final String rs in <String>['geosite-ads.srs', 'geosite-ir.srs']) {
      final File src = File('assets/rulesets/$rs');
      if (src.existsSync()) await src.copy('${tmp.path}/$rs');
    }
    final String json = const JsonEncoder.withIndent('  ')
        .convert(cfg)
        .replaceAll(SingboxConfig.ruleSetBaseToken, tmp.path);
    final File f = File('${tmp.path}/config.json');
    await f.writeAsString(json);
    final ProcessResult r =
        await Process.run(core!, <String>['check', '-c', f.path]);
    final String out =
        (r.stdout.toString() + r.stderr.toString()).replaceAll(
            RegExp('\\x1B\\[[0-9;]*m'), '').trim();
    expect(out, isEmpty, reason: '$label was rejected by the core:\n$out');
    expect(r.exitCode, 0, reason: '$label exited ${r.exitCode}');
  }

  group('the core accepts what Nova emits', skip: core == null
      ? 'no bundled core for this platform'
      : null, () {
    test('the ordinary tunnel', () async {
      await accepts('tunnel', SingboxConfig.buildMap(_vless()));
    });

    test('rule mode with Iran bypass and ad blocking', () async {
      // The combination that carries the DNS rules, which is where the
      // deprecated format lived.
      await accepts(
        'rule mode',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(
              mode: SingboxMode.rule,
              bypassIran: true,
              blockAds: true,
              localRuleSets: true,
            )),
      );
    });

    test('global mode', () async {
      await accepts(
        'global',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(mode: SingboxMode.global)),
      );
    });

    test('direct mode', () async {
      await accepts(
        'direct',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(mode: SingboxMode.direct)),
      );
    });

    test('proxy mode (loopback inbound, no TUN)', () async {
      await accepts(
        'proxy mode',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(mixedInboundPort: 2080)),
      );
    });

    test('per-app routing (TUN plus loopback)', () async {
      await accepts(
        'per-app',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(
              mixedInboundPort: 2080,
              tunWithLocalProxy: true,
              includePackages: <String>['org.telegram.messenger'],
            )),
      );
    });

    test('the multi-node auto-select pool', () async {
      await accepts(
        'multi',
        SingboxConfig.buildMultiMap(<ProxyNode>[_vless(), _trojan()],
            options: const SingboxRouteOptions(
                mode: SingboxMode.rule, blockAds: true, localRuleSets: true)),
      );
    });

    test('the measuring core', () async {
      // Its own DNS block, separate from the tunnel's, and it carried the same
      // deprecated format.
      final built = SingboxConfig.buildMeasureMap(
        <ProxyNode>[_vless(), _trojan()],
        mixedPort: 10000,
        clashPort: 10001,
      );
      await accepts('measure', built.config);
    });

    test('no config still uses the deprecated DNS format', () async {
      // Belt and braces: the core only reports the deprecation when the
      // environment variable is absent, and this asserts on the text directly so
      // the reason is legible if it ever comes back.
      final Map<String, dynamic> cfg = SingboxConfig.buildMap(_vless(),
          options: const SingboxRouteOptions(
              mode: SingboxMode.rule, blockAds: true, localRuleSets: true));
      final Directory tmp = await Directory.systemTemp.createTemp('nova-dep');
      addTearDown(() => tmp.delete(recursive: true));
      for (final String rs in <String>['geosite-ads.srs', 'geosite-ir.srs']) {
        final File src = File('assets/rulesets/$rs');
        if (src.existsSync()) await src.copy('${tmp.path}/$rs');
      }
      final File f = File('${tmp.path}/c.json');
      await f.writeAsString(
          jsonEncode(cfg).replaceAll(SingboxConfig.ruleSetBaseToken, tmp.path));
      final ProcessResult r =
          await Process.run(core!, <String>['check', '-c', f.path]);
      final String out = r.stdout.toString() + r.stderr.toString();
      expect(out, isNot(contains('legacy DNS servers is deprecated')));
      expect(out, isNot(contains('ENABLE_DEPRECATED_LEGACY_DNS_SERVERS')));
    });
  });

  /// Starts the core on a real config and gives it a moment to fall over.
  ///
  /// The TUN inbound is swapped for a loopback one, because opening a tunnel
  /// needs root and a test must not. Everything this exists to catch lives in
  /// the DNS and outbound startup path, which is identical either way.
  Future<void> starts(String label, Map<String, dynamic> cfg, int port) async {
    final Directory tmp = await Directory.systemTemp.createTemp('nova-run');
    addTearDown(() => tmp.delete(recursive: true));
    for (final String rs in <String>['geosite-ads.srs', 'geosite-ir.srs']) {
      final File src = File('assets/rulesets/$rs');
      if (src.existsSync()) await src.copy('${tmp.path}/$rs');
    }
    final Map<String, dynamic> run = <String, dynamic>{...cfg};
    run['inbounds'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'mixed',
        'tag': 'test-in',
        'listen': '127.0.0.1',
        'listen_port': port,
      },
    ];
    final File f = File('${tmp.path}/run.json');
    await f.writeAsString(jsonEncode(run)
        .replaceAll(SingboxConfig.ruleSetBaseToken, tmp.path));

    final Process p = await Process.start(core!, <String>['run', '-c', f.path]);
    final StringBuffer out = StringBuffer();
    p.stdout.transform(utf8.decoder).listen(out.write);
    p.stderr.transform(utf8.decoder).listen(out.write);
    await Future<void>.delayed(const Duration(seconds: 3));
    p.kill();
    await p.exitCode;
    final String text =
        out.toString().replaceAll(RegExp('\\x1B\\[[0-9;]*m'), '');
    expect(text, isNot(contains('FATAL')),
        reason: '$label did not start:\n$text');
    expect(text, isNot(contains('deprecated')),
        reason: '$label logged a deprecation:\n$text');
  }

  group('the core STARTS on what Nova emits', skip: core == null
      ? 'no bundled core for this platform'
      : null, () {
    test('the ordinary tunnel', () async {
      await starts('tunnel', SingboxConfig.buildMap(_vless()), 18301);
    });

    test('rule mode with Iran bypass and ad blocking', () async {
      await starts(
        'rule mode',
        SingboxConfig.buildMap(_vless(),
            options: const SingboxRouteOptions(
              mode: SingboxMode.rule,
              bypassIran: true,
              blockAds: true,
              localRuleSets: true,
            )),
        18302,
      );
    });

    test('the measuring core', () async {
      final built = SingboxConfig.buildMeasureMap(
        <ProxyNode>[_vless(), _trojan()],
        mixedPort: 18303,
        clashPort: 18304,
      );
      await starts('measure', built.config, 18305);
    });
  });
}
