import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/tuner/connection_fixer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Connection Fixer connects once per candidate fingerprint. On macOS and
/// Linux full-device mode is the DEFAULT, and every connect in that mode needs
/// root to create the network adapter, so the app raised an administrator
/// prompt per candidate: six password dialogs, each branded `osascript` rather
/// than Nova, at a user who had just asked for help getting past the DPI.
/// Cancelling one did not stop the run; the next candidate simply prompted.
///
/// The fix measures with full-device mode off, since the fingerprint shapes the
/// TLS handshake to the server and full-device mode only changes how local
/// traffic is captured here, then restores it before the final connect.
class _RecordingController extends ProxyController {
  _RecordingController(this._settings);

  final SettingsController _settings;

  ProxyConnectionState _state = ProxyConnectionState.disconnected;
  @override
  ProxyConnectionState get state => _state;
  @override
  TrafficStats get traffic => TrafficStats.zero;
  @override
  ProxyProfile? get activeProfile => _active;
  ProxyProfile? _active;
  @override
  String? get lastError => null;

  /// The value of tunMode at the moment of each connect(). Every `true` here is
  /// one administrator prompt the user would have seen.
  final List<bool> connectsInTunMode = <bool>[];

  @override
  void selectProfile(ProxyProfile? profile) => _active = profile;

  @override
  Future<void> connect() async {
    connectsInTunMode.add(_settings.tunMode);
    _state = ProxyConnectionState.connected;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _state = ProxyConnectionState.disconnected;
    notifyListeners();
  }
}

Future<SettingsController> _settingsWithTun(bool tun) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'nova.desktop.tun': tun,
  });
  final SettingsController s =
      SettingsController(prefs: await SharedPreferences.getInstance());
  await s.setTunMode(tun);
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('measuring never raises an admin prompt, and the winner is applied in '
      'full-device mode', () async {
    final SettingsController settings = await _settingsWithTun(true);
    final _RecordingController proxy = _RecordingController(settings);
    final ConnectionFixer fixer = ConnectionFixer(proxy, settings);

    await fixer.run();

    expect(proxy.connectsInTunMode.isNotEmpty, isTrue,
        reason: 'the fixer must have connected at least once');
    // Every candidate measured with full-device mode OFF. Each true would be a
    // password dialog.
    final int prompts =
        proxy.connectsInTunMode.where((bool t) => t).length;
    expect(prompts, lessThanOrEqualTo(1),
        reason: 'at most the final connect may prompt; got $prompts prompts '
            'across ${proxy.connectsInTunMode.length} connects');
    // And the run must leave the user where they started.
    expect(settings.tunMode, isTrue,
        reason: 'full-device mode must be restored');
  });

  test('a user who was not in full-device mode is not switched into it',
      () async {
    final SettingsController settings = await _settingsWithTun(false);
    final _RecordingController proxy = _RecordingController(settings);

    await ConnectionFixer(proxy, settings).run();

    expect(proxy.connectsInTunMode.any((bool t) => t), isFalse);
    expect(settings.tunMode, isFalse,
        reason: 'the fixer must not turn full-device mode on for someone who '
            'had it off');
  });

  test('cancelling mid-run still restores full-device mode', () async {
    // Leaving a user silently switched out of full-device mode would be worse
    // than the prompts: nothing on screen would say their traffic had stopped
    // being captured device-wide.
    final SettingsController settings = await _settingsWithTun(true);
    final _RecordingController proxy = _RecordingController(settings);
    final ConnectionFixer fixer = ConnectionFixer(proxy, settings);

    final Future<FixOutcome> run = fixer.run();
    fixer.cancel();
    await run;

    expect(settings.tunMode, isTrue,
        reason: 'a cancelled run must not leave full-device mode off');
  });
}
