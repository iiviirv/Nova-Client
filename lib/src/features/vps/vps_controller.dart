import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/proxy_controller.dart';
import '../cloudflare/nova_panel.dart';
import '../profiles/profiles_controller.dart';
import '../relay/relay_controller.dart';
import 'insecure_http.dart';
import 'vps_admin_screen.dart';

/// Where the SSH "install it for me" path fetches the Nova node-agent installer
/// from. The script installs Node + xray-core + the Nova agent, wires a systemd
/// service, and colocates the admin panel behind xray on 443 (full-strict when
/// a domain is given, self-signed for the no-domain case).
const String kNodeInstallerUrl =
    'https://raw.githubusercontent.com/IRNova/Tools/main/nova-node.sh';

/// The manual "run it yourself" one-liner shown in the app. Kept in sync with
/// [kNodeInstallerUrl].
String novaNodeOneLiner({String? adminPassword, String? domain}) {
  final StringBuffer env = StringBuffer();
  if (domain != null && domain.trim().isNotEmpty) {
    env.write("NOVA_DOMAIN='${domain.trim()}' ");
  }
  if (adminPassword != null && adminPassword.isNotEmpty) {
    env.write("NOVA_ADMIN_PASS='$adminPassword' ");
  }
  return '${env}bash <(curl -fsSL $kNodeInstallerUrl)';
}

/// Build one user's vless:// share link. Mirrors the agent's /sub link format
/// exactly (VLESS + WS + TLS on :443), so a link shown here is identical to the
/// one the server would hand out. `insecure` adds allowInsecure=1 for the
/// no-domain (self-signed) case.
String buildUserVlessLink({
  required String host,
  required String wsPath,
  required String uuid,
  required String name,
  bool insecure = false,
  int port = 443,
}) {
  final Map<String, String> params = <String, String>{
    'encryption': 'none',
    'type': 'ws',
    'security': 'tls',
    'host': host,
    'path': wsPath,
    'sni': host,
  };
  if (insecure) params['allowInsecure'] = '1';
  final String query = params.entries
      .map((MapEntry<String, String> e) =>
          '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return 'vless://$uuid@$host:$port?$query#${Uri.encodeComponent(name)}';
}

/// A random RFC-4122 v4 UUID, for new panel users (their VLESS id).
String newVpsUuid() {
  final Random r = Random.secure();
  final List<int> b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final StringBuffer s = StringBuffer();
  for (int i = 0; i < 16; i++) {
    s.write(hex(i));
    if (i == 3 || i == 5 || i == 7 || i == 9) s.write('-');
  }
  return s.toString();
}

/// A VPS panel the user has connected and can manage again later. The password
/// is kept in the platform secure enclave, never in plain prefs.
class VpsPanel {
  const VpsPanel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.allowInsecure,
    this.password = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool allowInsecure;
  final String password;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'allowInsecure': allowInsecure,
        'password': password,
      };

  factory VpsPanel.fromJson(Map<String, dynamic> j) => VpsPanel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        allowInsecure: j['allowInsecure'] == true,
        password: j['password'] as String? ?? '',
      );

  VpsPanel withoutSecret() =>
      VpsPanel(id: id, name: name, baseUrl: baseUrl, allowInsecure: allowInsecure);
}

/// Phases the VPS connect/install flow moves through. The UI renders each.
enum VpsPhase {
  idle,
  sshConnecting,
  installing,
  waitingForAgent,
  loggingIn,
  importing,
  done,
  error,
}

/// Drives "Connect your VPS": either connect to an agent the user installed
/// themselves (manual), or SSH in and install it (auto). Both paths end the
/// same way: the app holds a working panel session, has imported the node as a
/// profile, and can open the full admin UI.
class VpsController extends ChangeNotifier {
  VpsController(this._profiles, this._proxy, this._relay);

  final ProfilesController _profiles;
  final ProxyController _proxy;
  final RelayController _relay;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  VpsPhase _phase = VpsPhase.idle;
  VpsPhase get phase => _phase;

  final List<String> _log = <String>[];
  List<String> get logLines => List<String>.unmodifiable(_log);

  String? _error;
  String? get error => _error;

  String? _baseUrl;
  String? get baseUrl => _baseUrl;

  String? _adminPassword;
  String? get adminPassword => _adminPassword;

  bool _allowInsecure = false;
  bool get allowInsecure => _allowInsecure;

  String? _importedProfileId;
  String? get importedProfileId => _importedProfileId;

  bool get isBusy =>
      _phase == VpsPhase.sshConnecting ||
      _phase == VpsPhase.installing ||
      _phase == VpsPhase.waitingForAgent ||
      _phase == VpsPhase.loggingIn ||
      _phase == VpsPhase.importing;

  /// Reset back to the entry state so the flow can be re-run.
  void reset() {
    _phase = VpsPhase.idle;
    _log.clear();
    _error = null;
    _baseUrl = null;
    _adminPassword = null;
    _allowInsecure = false;
    _importedProfileId = null;
    notifyListeners();
  }

  void _setPhase(VpsPhase p) {
    _phase = p;
    notifyListeners();
  }

  void _append(String line) {
    for (final String l in const LineSplitter().convert(line)) {
      if (l.trim().isEmpty) continue;
      _log.add(l);
    }
    notifyListeners();
  }

  // When the Google relay is active, reach the panel through it (so a blocked
  // panel domain is still manageable); otherwise talk directly, allowing a
  // self-signed cert for the no-domain case.
  http.Client? _clientFor(bool allowInsecure) =>
      _relay.clientOrNull() ?? (allowInsecure ? buildInsecureClient() : null);

  static String _normalizeBase(String raw) {
    String u = raw.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http')) u = 'https://$u';
    u = u.replaceAll(RegExp(r'/+$'), '');
    return u;
  }

  // ---------------------------------------------------------------------------
  // Manual path: the user already ran the installer; just connect to the panel.
  // ---------------------------------------------------------------------------

  Future<bool> connectManual({
    required String address,
    required String password,
    bool allowInsecure = false,
  }) async {
    _error = null;
    _allowInsecure = allowInsecure;
    final String base = _normalizeBase(address);
    _setPhase(VpsPhase.loggingIn);
    final NovaPanel panel = NovaPanel(client: _clientFor(allowInsecure));
    try {
      // First run: if the freshly installed agent has no password yet, set the
      // one the user typed here (keeps it out of the install one-liner / shell
      // history). Older agents without /install just fall through to login.
      try {
        final bool configured = await panel.installConfigured(base);
        if (!configured) await panel.installSet(base, password);
      } catch (_) {}
      final PanelSession session = await panel.login(base, password);
      _baseUrl = base;
      _adminPassword = password;
      _setPhase(VpsPhase.importing);
      await _importNode(panel, session);
      await _rememberPanel();
      _setPhase(VpsPhase.done);
      return true;
    } catch (e) {
      _error = _pretty(e);
      _setPhase(VpsPhase.error);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // SSH path: install the agent on the box, then connect like the manual path.
  // ---------------------------------------------------------------------------

  Future<bool> installViaSsh({
    required String host,
    int port = 22,
    required String user,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    required String adminPassword,
    String? domain,
    bool allowInsecure = false,
    bool persistCreds = false,
  }) async {
    _error = null;
    _log.clear();
    _allowInsecure = allowInsecure;
    SSHClient? client;
    try {
      _setPhase(VpsPhase.sshConnecting);
      _append('Connecting to $user@$host:$port ...');
      final SSHSocket socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 20),
      );
      client = SSHClient(
        socket,
        username: user,
        onPasswordRequest:
            (password != null && password.isNotEmpty) ? () => password : null,
        identities: (privateKeyPem != null && privateKeyPem.isNotEmpty)
            ? SSHKeyPair.fromPem(privateKeyPem, passphrase)
            : null,
      );
      await client.authenticated;
      _append('Authenticated. Installing the Nova node agent...');

      if (persistCreds) {
        await _saveSshCreds(host, user, password, privateKeyPem);
      }

      _setPhase(VpsPhase.installing);
      final String cmd = _installCommand(adminPassword: adminPassword, domain: domain);
      final SSHSession sh = await client.execute(cmd);
      sh.stdout.listen((data) => _append(utf8.decode(data, allowMalformed: true)));
      sh.stderr.listen((data) => _append(utf8.decode(data, allowMalformed: true)));
      await sh.done;
      final int code = sh.exitCode ?? -1;
      if (code != 0) {
        throw 'Installer exited with code $code. See the log above.';
      }

      final String base = _normalizeBase(
        (domain != null && domain.trim().isNotEmpty) ? domain.trim() : host,
      );
      _baseUrl = base;
      _adminPassword = adminPassword;

      _setPhase(VpsPhase.waitingForAgent);
      _append('Waiting for the agent to come up at $base ...');
      final bool up = await _waitForAgent(base, allowInsecure);
      if (!up) throw 'The agent did not become reachable at $base.';

      _setPhase(VpsPhase.loggingIn);
      final NovaPanel panel = NovaPanel(client: _clientFor(allowInsecure));
      final PanelSession session = await panel.login(base, adminPassword);
      _setPhase(VpsPhase.importing);
      await _importNode(panel, session);
      await _rememberPanel();
      _append('Done. Node imported.');
      _setPhase(VpsPhase.done);
      return true;
    } catch (e) {
      _error = _pretty(e);
      _append('Error: ${_pretty(e)}');
      _setPhase(VpsPhase.error);
      return false;
    } finally {
      client?.close();
    }
  }

  String _installCommand({required String adminPassword, String? domain}) {
    final StringBuffer b = StringBuffer();
    b.write('curl -fsSL $kNodeInstallerUrl -o /tmp/nova-node.sh && ');
    if (domain != null && domain.trim().isNotEmpty) {
      b.write("NOVA_DOMAIN='${_shq(domain.trim())}' ");
    }
    b.write("NOVA_ADMIN_PASS='${_shq(adminPassword)}' bash /tmp/nova-node.sh");
    return b.toString();
  }

  // Escape a value for single-quoted shell context.
  static String _shq(String v) => v.replaceAll("'", "'\\''");

  Future<bool> _waitForAgent(String base, bool allowInsecure) async {
    final NovaPanel panel = NovaPanel(client: _clientFor(allowInsecure));
    for (int i = 0; i < 30; i++) {
      try {
        // /install/status returns without auth once the agent is serving.
        await panel.installConfigured(base);
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Shared: import the node as a profile, then open admin / connect.
  // ---------------------------------------------------------------------------

  Future<void> _importNode(NovaPanel panel, PanelSession session) async {
    // No-domain (self-signed) case: embed the links INLINE. A subscription URL
    // would be refreshed later over the app's default, cert-validating client
    // and fail on the self-signed cert. The links are self-contained (each
    // carries allowInsecure=1), so we fetch them once here (over the insecure
    // panel client) and store the whole set as an inline subscription. The app
    // resolves it to every protocol node, so the urltest auto-selector picks
    // the fastest working one, no further HTTPS fetch.
    if (_allowInsecure) {
      try {
        final String content = (await panel.subContent(session)).trim();
        if (content.isNotEmpty) {
          // base64 (or plain) multi-link body; the app decodes + parses it.
          _addProfile(kind: ProxyKind.subscription, uri: content, sub: null);
          return;
        }
      } catch (_) {}
    }
    // Domain (real cert): a subscription URL auto-updates and reports usage.
    String sub;
    try {
      sub = await panel.importableSubscription(session);
    } catch (_) {
      sub = '${session.workerUrl}/sub';
    }
    _addProfile(kind: ProxyKind.subscription, uri: sub, sub: sub);
  }

  void _addProfile({required ProxyKind kind, required String uri, String? sub}) {
    final ProxyProfile profile = ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameForHost(_baseUrl ?? uri),
      kind: kind,
      uri: uri,
      subscriptionUrl: sub,
      updatedAt: DateTime.now(),
    );
    _profiles.add(profile);
    _importedProfileId = profile.id;
  }

  /// Import (if needed) then make the VPS node the active profile and connect.
  Future<void> connectNow() async {
    final String? id = _importedProfileId;
    if (id == null) return;
    ProxyProfile? p;
    for (final ProxyProfile x in _profiles.profiles) {
      if (x.id == id) {
        p = x;
        break;
      }
    }
    if (p == null) return;
    _profiles.setActive(p.id);
    _proxy.selectProfile(p);
    await _proxy.connect();
  }

  /// Push the full admin panel for the connected VPS.
  void openAdmin(BuildContext context) {
    final String? base = _baseUrl;
    final String? pass = _adminPassword;
    if (base == null || pass == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VpsAdminScreen(
          workerUrl: base,
          password: pass,
          title: _nameForHost(base),
          allowInsecure: _allowInsecure,
          relayClient: _relay.clientOrNull(),
        ),
      ),
    );
  }

  /// Re-import a saved VPS's node into the server list and connect the tunnel,
  /// in one step (for the "Connect" action on a saved panel). Reuses the manual
  /// connect (login + import + remember), then turns the tunnel on.
  Future<bool> connectSavedPanel(VpsPanel p) async {
    final bool ok = await connectManual(
      address: p.baseUrl,
      password: p.password,
      allowInsecure: p.allowInsecure,
    );
    if (ok) await connectNow();
    return ok;
  }

  /// Open the admin panel for a previously-saved VPS (manage anytime).
  void openAdminFor(BuildContext context, VpsPanel p) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VpsAdminScreen(
          workerUrl: p.baseUrl,
          password: p.password,
          title: p.name,
          allowInsecure: p.allowInsecure,
          relayClient: _relay.clientOrNull(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Saved panels (so every connected VPS stays manageable). Stored as one JSON
  // blob in the secure enclave, since it holds the admin passwords.
  // ---------------------------------------------------------------------------

  static const String _panelsKey = 'vps_panels';

  Future<List<VpsPanel>> loadPanels() async {
    final String? raw = await _secure.read(key: _panelsKey);
    if (raw == null || raw.isEmpty) return <VpsPanel>[];
    try {
      final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
      return arr
          .whereType<Map<String, dynamic>>()
          .map(VpsPanel.fromJson)
          .toList();
    } catch (_) {
      return <VpsPanel>[];
    }
  }

  Future<void> _rememberPanel() async {
    final String? base = _baseUrl;
    final String? pass = _adminPassword;
    if (base == null || pass == null) return;
    final List<VpsPanel> panels = await loadPanels();
    final VpsPanel entry = VpsPanel(
      id: Uri.tryParse(base)?.host ?? base,
      name: _nameForHost(base),
      baseUrl: base,
      allowInsecure: _allowInsecure,
      password: pass,
    );
    // De-dupe by host: reconnecting updates the saved credentials.
    panels.removeWhere((VpsPanel p) => p.id == entry.id);
    panels.add(entry);
    await _secure.write(key: _panelsKey, value: jsonEncode(panels));
    notifyListeners();
  }

  Future<void> removePanel(String id) async {
    final List<VpsPanel> panels = await loadPanels();
    panels.removeWhere((VpsPanel p) => p.id == id);
    await _secure.write(key: _panelsKey, value: jsonEncode(panels));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Saved SSH credentials (optional, in the platform secure enclave).
  // ---------------------------------------------------------------------------

  String _credKey(String host) => 'vps_ssh_${host.trim().toLowerCase()}';

  Future<void> _saveSshCreds(
    String host,
    String user,
    String? password,
    String? privateKeyPem,
  ) async {
    final Map<String, String?> data = <String, String?>{
      'user': user,
      'password': password,
      'key': privateKeyPem,
    };
    await _secure.write(key: _credKey(host), value: jsonEncode(data));
  }

  Future<Map<String, dynamic>?> loadSshCreds(String host) async {
    final String? raw = await _secure.read(key: _credKey(host));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> forgetSshCreds(String host) async {
    await _secure.delete(key: _credKey(host));
  }

  // ---------------------------------------------------------------------------

  static String _nameForHost(String base) {
    final Uri? u = Uri.tryParse(base);
    final String h = u?.host ?? base;
    return h.isEmpty ? 'My VPS' : h;
  }

  static String _pretty(Object e) {
    if (e is PanelException) return e.message;
    if (e is SSHAuthFailError) {
      return 'SSH login failed: check the username and password/key.';
    }
    String s = e.toString();
    if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
    return s;
  }
}
