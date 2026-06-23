import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_logo.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';

/// App settings — theme, language, and the Nova Proxy links. The bilingual
/// (English / فارسی) toggle flips the whole app to RTL when Persian is chosen.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeController theme = NovaScope.of(context).theme;
    final s = NovaStrings.of(context);
    final nova = context.nova;

    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: ListView(
              padding: const EdgeInsets.all(NovaSpace.xl),
              children: <Widget>[
                Text(s.navSettings,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: NovaSpace.lg),

                // Appearance
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const NovaEyebrow('Appearance'),
                      const SizedBox(height: NovaSpace.md),
                      _Row(
                        label: s.theme,
                        child: Wrap(
                          spacing: 8,
                          children: <Widget>[
                            NovaPill(
                              label: 'Dark',
                              icon: Icons.dark_mode,
                              selected: theme.themeMode == ThemeMode.dark,
                              onTap: () => theme.setThemeMode(ThemeMode.dark),
                            ),
                            NovaPill(
                              label: 'Light',
                              icon: Icons.light_mode,
                              selected: theme.themeMode == ThemeMode.light,
                              onTap: () => theme.setThemeMode(ThemeMode.light),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: NovaSpace.md),
                      _Row(
                        label: s.language,
                        child: Wrap(
                          spacing: 8,
                          children: <Widget>[
                            NovaPill(
                              label: 'English',
                              selected: !theme.isFarsi,
                              onTap: () =>
                                  theme.setLocale(const Locale('en')),
                            ),
                            NovaPill(
                              label: 'فارسی',
                              selected: theme.isFarsi,
                              onTap: () =>
                                  theme.setLocale(const Locale('fa')),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),

                // Links
                NovaCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      _LinkTile(
                        icon: Icons.language,
                        title: 'novaproxy.online',
                        url: 'https://novaproxy.online/',
                      ),
                      Divider(height: 1, color: nova.border),
                      _LinkTile(
                        icon: Icons.send,
                        title: 'Telegram — @irnova_proxy',
                        url: 'https://t.me/irnova_proxy',
                      ),
                      Divider(height: 1, color: nova.border),
                      _LinkTile(
                        icon: Icons.code,
                        title: 'GitHub — IRNova',
                        url: 'https://github.com/IRNova',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.xl),

                // About
                Center(
                  child: Column(
                    children: <Widget>[
                      const NovaLogo(size: 48),
                      const SizedBox(height: NovaSpace.sm),
                      Text('Nova Client',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text('v0.1.0 · optimised Karing + Nova Radar',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: nova.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        child,
      ],
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.icon, required this.title, required this.url});
  final IconData icon;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return ListTile(
      shape: const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
      leading: Icon(icon, color: nova.cyan),
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      trailing: Icon(Icons.open_in_new, size: 16, color: nova.muted),
      onTap: () async {
        final Uri uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }
}
