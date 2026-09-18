import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared HTTP proxy authenticates and uses the selected outbound',
      () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    // A destination that cannot resolve directly. Only this stand-in upstream
    // can answer, so a successful response proves that the chosen exit was used.
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    addTearDown(() async {
      for (final s in sockets) {
        s.destroy();
      }
      await upstream.close(force: true);
    });
    var forwarded = 0;
    upstream.listen((request) async {
      expect(request.method, 'CONNECT');
      expect(request.uri.toString(), contains('nova-test.invalid'));
      forwarded++;
      request.response.statusCode = 200;
      final socket = await request.response.detachSocket();
      sockets.add(socket);
      socket.listen((_) {
        socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nselected-vpn'));
        socket.flush().then((_) => socket.destroy());
      });
    });
    final port = await AetherTunnel.freeLoopbackPort();
    final controller = DesktopProxyController(
        socksPort: port, clashPort: await AetherTunnel.freeLoopbackPort())
      ..proxyShareProvider = () => (onLan: true, user: 'nova', pass: 'secret');
    addTearDown(controller.dispose);
    final profile = ProxyProfile(
      id: 'lan-runtime',
      name: 'LAN runtime',
      kind: ProxyKind.singboxConfig,
      updatedAt: DateTime(2026),
      uri: jsonEncode({
        'inbounds': [],
        'outbounds': [
          {
            'type': 'http',
            'tag': 'proxy',
            'server': '127.0.0.1',
            'server_port': upstream.port
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': 'proxy'},
      }),
    );
    final config = await controller.buildConfigForTest(profile);
    final inbounds = (jsonDecode(config)['inbounds'] as List).cast<Map>();
    final internal = inbounds.singleWhere((i) => i['tag'] == 'nova-private');
    expect(internal['listen'], '127.0.0.1');
    final dir = await Directory.systemTemp.createTemp('nova-lan-runtime-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.json');
    await file.writeAsString(config);
    final executable = Platform.isMacOS
        ? (Abi.current() == Abi.macosArm64
            ? 'assets/bin/sing-box-macos-arm64'
            : 'assets/bin/sing-box-macos-amd64')
        : (Platform.isWindows
            ? 'assets/bin/sing-box-windows-amd64.exe'
            : 'assets/bin/sing-box-linux-amd64');
    final process = await Process.start(executable, ['run', '-c', file.path]);
    final log = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    var ready = false;
    for (var i = 0; i < 60; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        ready = true;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    expect(ready, isTrue, reason: log.toString());

    Future<({int status, String body})> fetch(int proxyPort,
        {String? password, bool connect = false}) async {
      final socket = await Socket.connect('127.0.0.1', proxyPort);
      final chunks = <int>[];
      final done = Completer<void>();
      var sentInsideTunnel = false;
      socket.listen((data) {
        chunks.addAll(data);
        final received = utf8.decode(chunks);
        if (connect && !sentInsideTunnel &&
            received.startsWith('HTTP/1.1 200') && received.contains('\r\n\r\n')) {
          sentInsideTunnel = true;
          socket.write('GET /check HTTP/1.1\r\nHost: nova-test.invalid\r\nConnection: close\r\n\r\n');
        }
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, onError: (Object _) {
        if (!done.isCompleted) done.complete();
      });
      try {
        socket.write(connect
            ? 'CONNECT nova-test.invalid:443 HTTP/1.1\r\nHost: nova-test.invalid:443\r\n'
            : 'GET http://nova-test.invalid/check HTTP/1.1\r\nHost: nova-test.invalid\r\nConnection: close\r\n');
        if (password != null) {
          socket.write(
              'Proxy-Authorization: Basic ${base64Encode(utf8.encode('nova:$password'))}\r\n');
        }
        socket.write('\r\n');
        await socket.flush();
        await done.future.timeout(const Duration(seconds: 3));
        final response = utf8.decode(chunks);
        expect(response, startsWith('HTTP/1.1 '), reason: log.toString());
        final parts = response.split('\r\n\r\n');
        return (
          status: int.parse(parts.first.split(' ')[1]),
          body: parts.skip(1).join('\r\n\r\n')
        );
      } finally {
        socket.destroy();
      }
    }

    expect((await fetch(port)).status, 407);
    expect((await fetch(port, password: 'wrong')).status, 407);
    expect((await fetch(port, connect: true)).status, 407);
    expect((await fetch(port, password: 'wrong', connect: true)).status, 407);
    expect(forwarded, 0);
    expect(await fetch(port, password: 'secret'),
        (status: 200, body: 'selected-vpn'));
    expect(await fetch(internal['listen_port'] as int),
        (status: 200, body: 'selected-vpn'));
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:${internal['listen_port']}');
    try {
      final request =
          await client.getUrl(Uri.parse('http://nova-test.invalid/check'));
      final response =
          await request.close().timeout(const Duration(seconds: 3));
      expect(await utf8.decodeStream(response), 'selected-vpn');
    } finally {
      client.close(force: true);
    }
    final tunnelled = await fetch(port, password: 'secret', connect: true);
    expect(tunnelled.status, 200);
    expect(tunnelled.body, endsWith('selected-vpn'));
    expect(forwarded, 4);

    // TUN mode must retain the original tunnel beside those same listeners.
    controller.tunModeProvider = () => true;
    final tunProfile = profile.copyWith(
        uri: jsonEncode({
      ...jsonDecode(profile.uri) as Map<String, dynamic>,
      'inbounds': [
        {'type': 'tun', 'tag': 'original-tun', 'mtu': 4064}
      ],
    }));
    final tunConfig =
        jsonDecode(await controller.buildConfigForTest(tunProfile));
    expect(
        (tunConfig['inbounds'] as List).where((i) => i['type'] == 'tun').single,
        {'type': 'tun', 'tag': 'original-tun', 'mtu': 4064});
    expect(
        (tunConfig['inbounds'] as List).where((i) => i['listen'] == '0.0.0.0'),
        hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
