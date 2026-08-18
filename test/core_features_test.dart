import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// The gap this covers: the Dart layer emitted a correct AmneziaWG endpoint for
/// months while the bundled core had no AmneziaWG in it, and nothing in the app
/// compared the two. These tests pin the comparison so the two halves cannot
/// drift apart in silence again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nova.proxy/control');
  const EventChannel events = EventChannel('nova.proxy/events');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const String awgConf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMDA=
Address = 10.8.1.2/32
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890

[Peer]
PublicKey = cHVibGljIGtleSBwdWJsaWMga2V5IHB1YmxpYyBrZQ=
AllowedIPs = 0.0.0.0/0
Endpoint = 198.51.100.7:51820
''';

  String awgConfigJson() => jsonEncode(<String, dynamic>{
        'endpoints': <Map<String, dynamic>>[
          AwgConfig.parseConf(awgConf).toEndpoint('proxy'),
        ],
      });

  tearDown(() {
    messenger.setMockMethodCallHandler(control, null);
  });

  group('usesAwg', () {
    test('sees the endpoint the AmneziaWG config layer actually emits', () {
      expect(CoreFeatures.usesAwg(awgConfigJson()), isTrue);
    });

    test('a plain WireGuard config does not claim to need AmneziaWG', () {
      final String wg = awgConf
          .replaceAll(RegExp(r'^(Jc|Jmin|Jmax|H1|H2|H3|H4) .*\n', multiLine: true), '');
      final Map<String, dynamic> ep = AwgConfig.parseConf(wg).toEndpoint('proxy');
      expect(ep['type'], 'wireguard');
      expect(
        CoreFeatures.usesAwg(jsonEncode(<String, dynamic>{
          'endpoints': <Map<String, dynamic>>[ep],
        })),
        isFalse,
      );
    });

    test('an ordinary VLESS config and malformed JSON are both false', () {
      expect(
        CoreFeatures.usesAwg(jsonEncode(<String, dynamic>{
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'vless', 'tag': 'proxy'},
          ],
        })),
        isFalse,
      );
      expect(CoreFeatures.usesAwg('not json at all'), isFalse);
    });
  });

  group('the core probe', () {
    test('a core that answers yes is not treated as a problem', () async {
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        if (call.method != 'coreFeatures') return null;
        return <String, Object>{'amneziawg': true, 'coreVersion': '1.13.13'};
      });
      final CoreFeatures f = CoreFeatures(control: control);
      await f.load();
      expect(f.awgUnsupported, isFalse);
      expect(f.awgUnknown, isFalse);
      expect(f.coreVersion, '1.13.13');
    });

    test('a core that answers no carries its own reason', () async {
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        if (call.method != 'coreFeatures') return null;
        return <String, Object>{
          'amneziawg': false,
          'amneziawgReason': 'Awg is not included in this build',
        };
      });
      final CoreFeatures f = CoreFeatures(control: control);
      await f.load();
      expect(f.awgUnsupported, isTrue);
      expect(f.awgUnsupportedMessage, contains('not included in this build'));
    });

    test('an answer with no verdict stays unknown, reason and all', () async {
      // The Android host omits the key when the probe could not answer, so a
      // failure unrelated to protocol support cannot lock a customer out of a
      // protocol their build actually has.
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        if (call.method != 'coreFeatures') return null;
        return <String, Object>{
          'coreVersion': '1.13.13',
          'amneziawgReason': 'out of memory while building the probe',
        };
      });
      final CoreFeatures f = CoreFeatures(control: control);
      await f.load();
      expect(f.awgUnknown, isTrue);
      expect(f.awgUnsupported, isFalse);
      expect(f.awgReason, contains('out of memory'));
    });

    test('a host with no probe stays unknown and accuses nobody', () async {
      // No handler registered: the call raises MissingPluginException, which is
      // every platform host that has not implemented the probe yet.
      final CoreFeatures f = CoreFeatures(control: control);
      await f.load();
      expect(f.awgUnknown, isTrue);
      expect(f.awgUnsupported, isFalse);
    });
  });

  group('connect', () {
    ProxyProfile awgProfile() => ProxyProfile(
          id: 'awg',
          name: 'AmneziaWG node',
          kind: ProxyKind.awg,
          uri: awgConf,
        );

    test('refuses an AmneziaWG config on a core without it, and says why',
        () async {
      final List<String> started = <String>[];
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        if (call.method == 'start') {
          started.add(call.method);
          return null;
        }
        if (call.method == 'coreFeatures') {
          return <String, Object>{
            'amneziawg': false,
            'amneziawgReason': 'Awg is not included in this build',
          };
        }
        return null;
      });

      final SingboxProxyController c = SingboxProxyController(
        control: control,
        events: events,
        features: CoreFeatures(control: control),
      );
      c.selectProfile(awgProfile());
      await c.connect();

      expect(started, isEmpty, reason: 'the core is never handed the config');
      expect(c.state, ProxyConnectionState.error);
      expect(c.lastError, contains('AmneziaWG'));
    });

    test('starts normally when the core reports AmneziaWG support', () async {
      final List<String> started = <String>[];
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        if (call.method == 'start') {
          started.add(call.arguments['configJson'] as String);
          return null;
        }
        if (call.method == 'coreFeatures') {
          return <String, Object>{'amneziawg': true};
        }
        return null;
      });

      final SingboxProxyController c = SingboxProxyController(
        control: control,
        events: events,
        features: CoreFeatures(control: control),
      );
      c.selectProfile(awgProfile());
      await c.connect();

      expect(started, hasLength(1));
      expect(CoreFeatures.usesAwg(started.single), isTrue,
          reason: 'the document handed over is the AmneziaWG one');
      expect(c.state, isNot(ProxyConnectionState.error));
    });
  });
}
