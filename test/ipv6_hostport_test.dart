import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/features/radar/models.dart';

/// Splitting a host from a port is where IPv6 quietly breaks things. An address
/// is full of colons, so the rule that works for IPv4 reads a bare
/// `2606:4700::1` as host `2606:4700:` on port 1: wrong, and silently so, which
/// is how it would have reached a config as a dead address rather than an
/// error anyone could see.
void main() {
  test('a bracketed v6 address splits into host and port', () {
    expect(splitHostPortForTest('[2606:4700::1]:443'),
        ('2606:4700::1', 443));
    expect(splitHostPortForTest('[2606:4700::6812:a76]:8443'),
        ('2606:4700::6812:a76', 8443));
  });

  test('a bare v6 address keeps all of itself and claims no port', () {
    expect(splitHostPortForTest('2606:4700::1'), ('2606:4700::1', 0),
        reason: 'the old rule returned ("2606:4700:", 1) here');
  });

  test('IPv4 and names are unchanged', () {
    expect(splitHostPortForTest('104.16.0.1:443'), ('104.16.0.1', 443));
    expect(splitHostPortForTest('example.com:2096'), ('example.com', 2096));
    expect(splitHostPortForTest('example.com'), ('example.com', 0));
  });

  test('a scan result writes an address that can be read back', () {
    final ScanResult v6 = ScanResult(
        ip: '2606:4700::1', port: 443, link: '', latencyMs: 10);
    expect(v6.hostPort, '[2606:4700::1]:443');
    expect(splitHostPortForTest(v6.hostPort), ('2606:4700::1', 443),
        reason: 'what the scanner writes must survive what the parser reads');

    final ScanResult v4 =
        ScanResult(ip: '104.16.0.1', port: 443, link: '', latencyMs: 10);
    expect(v4.hostPort, '104.16.0.1:443');
    expect(splitHostPortForTest(v4.hostPort), ('104.16.0.1', 443));
  });
}
