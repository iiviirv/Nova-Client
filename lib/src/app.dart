import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/models/proxy_profile.dart';
import 'core/platform/windows_url_scheme.dart';
import 'core/proxy/conn_info_controller.dart';
import 'core/proxy/proxy_controller.dart';
import 'features/cloudflare/cloudflare_controller.dart';
import 'features/profiles/profiles_controller.dart';
import 'features/radar/radar_controller.dart';
import 'features/settings/settings_controller.dart';
import 'features/relay/relay_controller.dart';
import 'features/relay/tunnel_controller.dart';
import 'features/vps/vps_controller.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'l10n/nova_strings.dart';
import 'theme/nova_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/nova_app_shell.dart';
import 'widgets/nova_splash.dart';
import 'widgets/nova_scope.dart';
import 'core/update/update_checker.dart';

/// The Nova Client application root. Owns the long-lived controllers, exposes
/// them through [NovaScope], and rebuilds [MaterialApp] when the theme or
/// locale changes.
class NovaApp extends StatelessWidget {
  const NovaApp({
    super.key,
    required this.theme,
    required this.proxy,
    required this.connInfo,
    required this.profiles,
    required this.radar,
    required this.cloudflare,
    required this.settings,
    required this.vps,
    required this.relay,
    required this.tunnel,
  });

  final ThemeController theme;
  final ProxyController proxy;
  final ConnInfoController connInfo;
  final ProfilesController profiles;
  final RadarController radar;
  final CloudflareController cloudflare;
  final SettingsController settings;
  final VpsController vps;
  final RelayController relay;
  final TunnelController tunnel;

  @override
  Widget build(BuildContext context) {
    return NovaScope(
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
      child: ListenableBuilder(
        listenable: theme,
        builder: (context, _) {
          return MaterialApp(
            title: 'Nova Client',
            debugShowCheckedModeBanner: false,
            themeMode: theme.themeMode,
            theme: NovaTheme.light(theme.locale),
            darkTheme: NovaTheme.dark(theme.locale),
            locale: theme.locale,
            supportedLocales: ThemeController.supportedLocales,
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              NovaStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _RootGate(theme: theme),
          );
        },
      ),
    );
  }
}

/// Chooses between onboarding and the app shell once prefs have loaded, and
/// carries the onboarding "how to start" choice into the shell.
class _RootGate extends StatefulWidget {
  const _RootGate({required this.theme});
  final ThemeController theme;

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> with WidgetsBindingObserver {
  String? _startAction;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  // Hold the branded splash for a short minimum so its tagline is actually seen,
  // instead of flashing past the instant prefs finish loading.
  bool _minSplash = true;
  Timer? _splashTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start the minimum-splash hold only AFTER the first frame actually paints.
    // Measuring it from initState would race the first build on a slow cold
    // start (the timer and the frame come due together on the one isolate), so
    // the splash could flash past unseen. Post-frame guarantees a full hold from
    // the moment the splash is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NovaScope.of(context).proxy.syncStatus();
      _splashTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _minSplash = false);
      });
    });
    // Windows has to register its own URL schemes (no manifest does it), and a
    // nova:// link did nothing there until it did. No-op elsewhere.
    registerWindowsUrlSchemes();
    _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _splashTimer?.cancel();
    _linkSub?.cancel();
    super.dispose();
  }

  /// The panel's share page offers a one-tap import as `nova://install-config?
  /// url=<sub url>` (also accept the app's own `novaclient://`). Register both
  /// schemes so the OS hands the link to us instead of Safari saying the address
  /// is invalid, then add the subscription. Handles cold start and while running.
  Future<void> _initDeepLinks() async {
    try {
      final Uri? initial = await _appLinks.getInitialLink();
      if (initial != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _handleUri(initial));
      }
    } catch (_) {/* no initial link */}
    _linkSub = _appLinks.uriLinkStream.listen(_handleUri, onError: (_) {});
  }

  void _handleUri(Uri uri) {
    // nova://install-config?url=<encoded sub url>. The action is the host
    // (nova://install-config) or the first path segment, depending on the OS.
    final String action =
        uri.host.isNotEmpty ? uri.host : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '');
    if (action != 'install-config') return;
    final String sub = (uri.queryParameters['url'] ?? '').trim();
    if (sub.isEmpty) return;
    _importSubscription(sub);
  }

  void _importSubscription(String url) {
    if (!mounted) return;
    final NovaScope scope = NovaScope.of(context);
    ProxyProfile? existing;
    for (final ProxyProfile p in scope.profiles.profiles) {
      if (p.subscriptionUrl == url) {
        existing = p;
        break;
      }
    }
    final ProxyProfile profile = existing ??
        ProxyProfile(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: 'Nova subscription',
          kind: ProxyKind.subscription,
          uri: '',
          subscriptionUrl: url,
          updatedAt: DateTime.now(),
        );
    if (existing == null) scope.profiles.add(profile);
    scope.profiles.setActive(profile.id);
    scope.proxy.selectProfile(profile);
    // The new subscription shows in the server list and becomes active; the
    // ProfilesController notifies listeners, so the UI updates on its own.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On return to foreground, re-read the tunnel state so a still-connected
    // VPN isn't shown as off.
    if (state == AppLifecycleState.resumed && mounted) {
      NovaScope.of(context).proxy.syncStatus();
      // Also look for a new release on return to the app, not only at a cold
      // start: many users never fully quit it. Gated (see
      // kUpdateCheckGateMs), best-effort, never blocks.
      unawaited(SharedPreferences.getInstance().then((SharedPreferences p) =>
          checkForNovaUpdate(p, nowMs: DateTime.now().millisecondsSinceEpoch)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.theme,
      builder: (context, _) {
        if (!widget.theme.loaded || _minSplash) {
          return const NovaSplash();
        }
        if (!widget.theme.onboarded) {
          return NovaOnboarding(
            onPickLanguage: (String code) => widget.theme.setLocale(Locale(code)),
            onFinish: (String? action) {
              widget.theme.setOnboarded();
              setState(() => _startAction = action);
            },
          );
        }
        return NovaAppShell(startAction: _startAction);
      },
    );
  }
}
