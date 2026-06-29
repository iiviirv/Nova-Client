import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/proxy/proxy_controller.dart';
import 'features/cloudflare/cloudflare_controller.dart';
import 'features/profiles/profiles_controller.dart';
import 'features/radar/radar_controller.dart';
import 'l10n/nova_strings.dart';
import 'theme/nova_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/nova_app_shell.dart';
import 'widgets/nova_scope.dart';

/// The Nova Client application root. Owns the long-lived controllers, exposes
/// them through [NovaScope], and rebuilds [MaterialApp] when the theme or
/// locale changes.
class NovaApp extends StatelessWidget {
  const NovaApp({
    super.key,
    required this.theme,
    required this.proxy,
    required this.profiles,
    required this.radar,
    required this.cloudflare,
  });

  final ThemeController theme;
  final ProxyController proxy;
  final ProfilesController profiles;
  final RadarController radar;
  final CloudflareController cloudflare;

  @override
  Widget build(BuildContext context) {
    return NovaScope(
      theme: theme,
      proxy: proxy,
      profiles: profiles,
      radar: radar,
      cloudflare: cloudflare,
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
            home: const NovaAppShell(),
          );
        },
      ),
    );
  }
}
