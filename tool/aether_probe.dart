// A diagnostic harness: drives Nova's own Aether code against the real core and
// asks the question a 204 probe cannot answer, which is whether traffic is
// actually leaving through WARP or merely leaving.
//
// Run from the project root:  dart run tool/aether_probe.dart [masque|wg|gool]
import 'dart:convert';
import 'dart:io';

import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';

Future<String> _sh(List<String> args) async {
  final ProcessResult r = await Process.run(args.first, args.sublist(1));
  return '${r.stdout}'.trim();
}

/// Who the internet thinks we are. Cloudflare's trace is the right oracle here:
/// it reports the warp= state as well as the address, so a tunnel that carries
/// traffic but is not WARP cannot pass as one.
Future<Map<String, String>> _trace({String? socks}) async {
  final List<String> args = <String>[
    'curl', '-s', '--max-time', '25',
    if (socks != null) ...<String>['--socks5-hostname', socks],
    'https://www.cloudflare.com/cdn-cgi/trace',
  ];
  final String out = await _sh(args);
  final Map<String, String> m = <String, String>{};
  for (final String line in out.split('\n')) {
    final int i = line.indexOf('=');
    if (i > 0) m[line.substring(0, i)] = line.substring(i + 1).trim();
  }
  return m;
}

Future<void> main(List<String> argv) async {
  final String want = argv.isEmpty ? 'wg' : argv.first;
  final AetherMode mode = switch (want) {
    'masque' => AetherMode.masque,
    'gool' => AetherMode.gool,
    _ => AetherMode.wg,
  };
  final AetherOptions o = AetherOptions(mode: mode);

  stdout.writeln('mode      : ${mode.name}');
  stdout.writeln('scan  JSON: ${AetherPayloads.scan(o)}');
  stdout.writeln('tunnel JSON: '
      '${AetherPayloads.tunnel(o, endpoint: "1.2.3.4:443", socks: "127.0.0.1:1")}');

  final Map<String, String> direct = await _trace();
  stdout.writeln('direct    : ip=${direct["ip"]} warp=${direct["warp"]} '
      'loc=${direct["loc"]}');

  final AetherCore core = AetherCore.open();
  stdout.writeln('core      : ${core.version()}');

  final Directory dir =
      await Directory.systemTemp.createTemp('aether_probe_');
  final String base = '${dir.path}/aether';

  // Identity, then scan, then tunnel: the same three steps the app takes.
  final AetherReply idReply = core.identityOpen(o, base: base);
  if (!idReply.ok) {
    stdout.writeln('identity  : FAILED ${idReply.error}');
    exit(1);
  }
  int? id;
  for (int i = 0; i < 240; i++) {
    final AetherJobStatus st = core.jobPoll((idReply['job'] as num).toInt());
    if (st.state == AetherJobState.done) {
      id = (st.result?[kAetherIdentityField] as num?)?.toInt();
      break;
    }
    if (st.state == AetherJobState.failed) {
      stdout.writeln('identity  : FAILED ${st.error}');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (id == null) {
    stdout.writeln('identity  : timed out');
    exit(1);
  }
  stdout.writeln('identity  : handle $id');

  final AetherReply scan = core.scanStart(id, o);
  if (!scan.ok) {
    stdout.writeln('scan      : FAILED ${scan.error}');
    exit(1);
  }
  String? endpoint;
  for (int i = 0; i < 600; i++) {
    final AetherJobStatus st = core.jobPoll((scan['job'] as num).toInt());
    if (st.state == AetherJobState.done) {
      endpoint = AetherEndpoint.parse(
          st.result?['endpoint'] ?? st.result?['result'] ?? st.result?['peer']);
      stdout.writeln('scan raw  : ${jsonEncode(st.result)}');
      break;
    }
    if (st.state == AetherJobState.failed) {
      stdout.writeln('scan      : FAILED ${st.error}');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (endpoint == null) {
    stdout.writeln('scan      : no endpoint');
    exit(1);
  }
  stdout.writeln('endpoint  : $endpoint');

  final AetherTunnel t =
      await AetherTunnel.start(o, endpoint: endpoint, identityBase: base);
  stdout.writeln('socks     : 127.0.0.1:${t.socksPort}');

  final Map<String, String> through = await _trace(socks: '127.0.0.1:${t.socksPort}');
  stdout.writeln('through   : ip=${through["ip"]} warp=${through["warp"]} '
      'loc=${through["loc"]}');

  // Watch the tunnel job rather than checking it once. Nova checks it only at
  // startup, so a core that gives up later is never noticed and the app keeps
  // pointing sing-box at a port nothing is listening on.
  for (int i = 0; i < 18; i++) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final AetherJobStatus st = core.jobPoll(t.job);
    bool serving;
    try {
      final Socket s = await Socket.connect('127.0.0.1', t.socksPort,
          timeout: const Duration(milliseconds: 500));
      s.destroy();
      serving = true;
    } catch (_) {
      serving = false;
    }
    stdout.writeln('t+${(i + 1) * 5}s   job=${st.state.name} '
        'serving=$serving ${st.error ?? ""}');
    if (st.state == AetherJobState.failed || !serving) break;
  }

  final String? ip = through['ip'];
  if (ip == null || ip.isEmpty) {
    stdout.writeln('VERDICT   : NO TRAFFIC through the tunnel');
  } else if (ip == direct['ip']) {
    stdout.writeln('VERDICT   : LEAK, exit IP equals the direct IP');
  } else if (through['warp'] == 'on' || through['warp'] == 'plus') {
    stdout.writeln('VERDICT   : WARP, carried through the tunnel');
  } else {
    stdout.writeln('VERDICT   : different IP but warp=${through["warp"]}');
  }
  await AetherTunnel.stop();
  await dir.delete(recursive: true);
}
