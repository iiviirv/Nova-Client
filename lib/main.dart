import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/core/desktop/tray_controller.dart';
import 'src/core/geo/node_geo_store.dart';
import 'src/core/proxy/conn_info_controller.dart';
import 'src/core/proxy/desktop_proxy_controller.dart';
import 'src/core/proxy/mock_proxy_controller.dart';
import 'src/core/proxy/proxy_controller.dart';
import 'src/core/proxy/singbox_proxy_controller.dart';
import 'src/core/proxy/subscription.dart';
import 'src/core/proxy/subscription_body_store.dart';
import 'src/core/update/update_checker.dart';
import 'src/features/cloudflare/cloudflare_controller.dart';
import 'src/features/profiles/profiles_controller.dart';
import 'src/features/radar/radar_controller.dart';
import 'src/features/relay/relay_controller.dart';
import 'src/features/relay/tunnel_controller.dart';
import 'src/features/settings/settings_controller.dart';
import 'src/features/vps/vps_controller.dart';
import 'src/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Construct controllers up front so the first frame is correct, then attach
  // persisted state once SharedPreferences resolves.
  final ThemeController theme = ThemeController();
  final ProfilesController profiles = ProfilesController();
  final RadarController radar = RadarController();
  final CloudflareController cloudflare = CloudflareController();
  final SettingsController settings = SettingsController();

  // The Google relay: fetch subscriptions and reach the /admin API through a
  // Google Apps Script front when the panel's own domain is blocked.
  final RelayController relay = RelayController();

  // The full tunnel: a local SOCKS5 that carries real traffic through a node
  // /tunnel exit, riding the relay's fronted/insecure transport.
  final TunnelController tunnel = TunnelController(relay.transportFor);

  // The data path is a modified sing-box core, bound per platform. Android ships
  // the VpnService + libbox host; desktop (macOS/Windows/Linux) runs the bundled
  // sing-box process from pure Dart; iOS and tests use the simulated controller
  // until their hosts land.
  final bool isDesktop =
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  // Android + iOS share the MethodChannel host (VpnService / NetworkExtension);
  // desktop runs the bundled sing-box from Dart; anything else is simulated.
  final ProxyController proxy = (Platform.isAndroid || Platform.isIOS)
      ? SingboxProxyController()
      : isDesktop
          ? DesktopProxyController()
          : MockProxyController();

  final ConnInfoController connInfo = ConnInfoController(proxy);

  // "Connect your VPS": installs/manages the Nova node agent on the user's own
  // server and imports its node into the profile list.
  final VpsController vps = VpsController(profiles, proxy, relay);

  // The host builds each config from the user's live routing/DNS choices.
  proxy.routeOptionsProvider = () => settings.routeOptions;

  // Route subscription refresh through the relay when it is active.
  proxy.subFetcherProvider = () => relay.subFetcher();

  // Let the controller persist a profile it mutates itself (clearing a dead
  // pinned exit during auto-failover) so the Servers list reflects the switch.
  proxy.persistProfile = (profile) async => profiles.update(profile);

  // Desktop can run a whole-device TUN (elevated) instead of a system proxy.
  if (proxy is DesktopProxyController) {
    final DesktopProxyController desktop = proxy;
    desktop.tunModeProvider = () => settings.tunMode;
    desktop.autoSystemProxyProvider = () => settings.autoSystemProxy;
    // Proxy mode's port follows Settings, so a user whose 2080 is taken by
    // another proxy app can move Nova instead of uninstalling one of them.
    desktop.socksPort = settings.proxyPort;
    settings.addListener(() => desktop.socksPort = settings.proxyPort);
  }
  if (proxy is SingboxProxyController) {
    proxy.autoReconnectProvider = () => settings.iosAutoReconnect;
    // Proxy mode on a phone: no TUN, a loopback SOCKS5/HTTP port instead, so
    // the device keeps its own connection and only an app pointed at the port
    // goes through Nova.
    proxy.proxyPortProvider =
        () => settings.mobileProxyMode ? settings.proxyPort : null;
  }

  // Windows and macOS: a menu-bar / notification-area icon, so closing the
  // window hides Nova instead of ending it and the tunnel keeps running with
  // nothing on screen. Started after the controllers exist because its menu
  // reflects the connection state.
  if (TrayController.supported) {
    final TrayController tray = TrayController(
      proxy,
      strings: () => trayStringsFor(theme.isFarsi),
    );
    theme.addListener(() => tray.refreshLabels());
    unawaited(tray.start());
  }

  runApp(NovaApp(
    theme: theme,
    proxy: proxy,
    connInfo: connInfo,
    profiles: profiles,
    radar: radar,
    cloudflare: cloudflare,
    settings: settings,
    vps: vps,
    relay: relay,
    tunnel: tunnel,
  ));

  // Hydrate persisted preferences without blocking first paint.
  relay.load();
  tunnel.load();
  SharedPreferences.getInstance().then((prefs) {
    theme.attachPrefs(prefs);
    profiles.attachPrefs(prefs);
    radar.attachPrefs(prefs);
    cloudflare.attachPrefs(prefs);
    settings.attachPrefs(prefs);
    NodeGeoStore.instance.attachPrefs(prefs);

    // Persist each subscription's last good body so a blocked refresh
    // (workers.dev filtered) serves the saved servers instead of wiping the
    // list and stranding the user with nothing to connect to.
    subscriptionBodyStore = PrefsSubscriptionBodyStore(prefs);

    // Once-a-day best-effort check for a newer release; a hit shows a small
    // banner on the dashboard. Never blocks startup and swallows any failure.
    unawaited(checkForNovaUpdate(prefs,
        nowMs: DateTime.now().millisecondsSinceEpoch));

    // If a subscription is active, bind it to the Radar in the background so
    // scans export ready-to-import nodes without the user lifting a finger.
    final active = profiles.active;
    if (active != null &&
        active.isSubscription &&
        (active.subscriptionUrl ?? '').isNotEmpty) {
      radar.bindSubscription(active.subscriptionUrl!);
    }
  });
}
