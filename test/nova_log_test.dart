import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

void main() {
  setUp(() {
    NovaLog.instance
      ..clear(NovaLogSource.app)
      ..clear(NovaLogSource.core);
  });

  group('the log buffer', () {
    test('keeps the app and the core apart', () {
      NovaLog.instance.write('Nova decided something');
      NovaLog.instance.writeCore('core said something');
      expect(NovaLog.instance.count(NovaLogSource.app), 1);
      expect(NovaLog.instance.count(NovaLogSource.core), 1);
      expect(NovaLog.instance.lines(NovaLogSource.app).single.message,
          'Nova decided something');
      expect(NovaLog.instance.lines(NovaLogSource.core).single.message,
          'core said something');
    });

    test('drops the oldest lines instead of growing without bound', () {
      for (int i = 0; i < NovaLog.maxLines + 50; i++) {
        NovaLog.instance.writeCore('line $i');
      }
      final List<NovaLogEntry> lines = NovaLog.instance.lines(
        NovaLogSource.core,
      );
      expect(lines.length, NovaLog.maxLines);
      expect(lines.first.message, 'line 50', reason: 'oldest dropped first');
      expect(lines.last.message, 'line ${NovaLog.maxLines + 49}');
    });

    test('strips the terminal colour codes the core wraps its levels in', () {
      // Measured on a device: libbox hands sing-box's TTY colouring through
      // untouched, so without this every line read as "<esc>[36mINFO<esc>[0m..."
      const String esc = '\u001b';
      NovaLog.instance.writeCore(
        '$esc[36mINFO$esc[0m$esc[0114] router: found fakeip',
      );
      expect(
        NovaLog.instance.lines(NovaLogSource.core).single.message,
        'INFO[0114] router: found fakeip',
      );
    });

    test('a line that merely contains brackets keeps them', () {
      NovaLog.instance.writeCore('outbound/vless[proxy]: dialed [::1]:443');
      expect(
        NovaLog.instance.lines(NovaLogSource.core).single.message,
        'outbound/vless[proxy]: dialed [::1]:443',
      );
    });

    test('ignores blank lines', () {
      NovaLog.instance.writeCore('   ');
      NovaLog.instance.writeCore('');
      expect(NovaLog.instance.count(NovaLogSource.core), 0);
    });

    test('clearing one stream leaves the other alone', () {
      NovaLog.instance.write('app');
      NovaLog.instance.writeCore('core');
      NovaLog.instance.clear(NovaLogSource.core);
      expect(NovaLog.instance.count(NovaLogSource.app), 1);
      expect(NovaLog.instance.count(NovaLogSource.core), 0);
    });
  });

  group('redaction', () {
    // This is what makes "copy your log into the support chat" safe to ask for:
    // a raw sing-box log names the servers AND can carry the UUID that IS the
    // user's subscription.
    test('a UUID is masked', () {
      expect(
        NovaLog.redact(
          'outbound/vless[proxy]: 12345678-90ab-cdef-1234-567890abcdef',
        ),
        'outbound/vless[proxy]: <uuid>',
      );
    });

    test('a subscription token is masked', () {
      expect(
        NovaLog.redact(
            'fetch https://n1.example.workers.dev/sub?token=37f660389291e5b5'),
        'fetch https://n1.example.workers.dev/sub?token=<token>',
      );
      expect(
        NovaLog.redact('password=hunter2 rest'),
        'password=<token> rest',
      );
    });

    test('credentials in a URL are masked', () {
      expect(
        NovaLog.redact('socks://alice:s3cret@10.0.0.1:1080'),
        'socks://<credentials>@10.0.0.1:1080',
      );
    });

    test('server addresses survive, because they are the evidence', () {
      const String line =
          'outbound: connect to 104.21.5.7:443 (sni=cdn.example.com) failed';
      expect(NovaLog.redact(line), line);
    });

    test('export redacts every line it returns', () {
      NovaLog.instance
          .writeCore('using 12345678-90ab-cdef-1234-567890abcdef now');
      final String out = NovaLog.instance.export(NovaLogSource.core);
      expect(out, contains('<uuid>'));
      expect(out, isNot(contains('12345678-90ab')));
    });
  });

  group('core levels', () {
    test('logrus levels map onto Nova severity', () {
      // sing-box uses logrus, where LOWER is more severe.
      expect(novaLogLevelFromCore(0), NovaLogLevel.error); // panic
      expect(novaLogLevelFromCore(2), NovaLogLevel.error); // error
      expect(novaLogLevelFromCore(3), NovaLogLevel.warn);
      expect(novaLogLevelFromCore(4), NovaLogLevel.info);
      expect(novaLogLevelFromCore(5), NovaLogLevel.debug);
      expect(novaLogLevelFromCore(6), NovaLogLevel.debug); // trace
    });
  });

  group('the core log level in the config', () {
    final ProxyNode node = ProxyNode(
      protocol: NodeProtocol.vless,
      server: 'example.com',
      port: 443,
      tls: true,
      uuid: '12345678-90ab-cdef-1234-567890abcdef',
    );

    test('is quiet by default', () {
      final Map<String, dynamic> cfg = SingboxConfig.buildMap(node);
      expect((cfg['log'] as Map<String, dynamic>)['level'], 'warn');
    });

    test('turning on detailed logging raises it to info', () {
      final Map<String, dynamic> cfg = SingboxConfig.buildMap(
        node,
        options: const SingboxRouteOptions(verboseCoreLog: true),
      );
      expect((cfg['log'] as Map<String, dynamic>)['level'], 'info');
    });

    test('the setting survives copyWith, which the connect path uses', () {
      const SingboxRouteOptions base =
          SingboxRouteOptions(verboseCoreLog: true);
      expect(base.copyWith(lean: true).verboseCoreLog, isTrue);
      expect(base.copyWith(lean: true).logLevel, 'info');
    });
  });
}
