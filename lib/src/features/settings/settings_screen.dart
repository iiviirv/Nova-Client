import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_logo.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../logs/log_screen.dart';
import '../radar/radar_screen.dart';
import '../relay/relay_screen.dart';
import '../routing/routing_screen.dart';

/// Shown in the Settings "About" footer so a tester can confirm exactly which
/// build is running. Keep in step with `pubspec.yaml`'s `version:` on release.
const String kNovaVersion = '0.3.3';
const String kNovaBuild = '74';

/// App settings: grouped cards (General, Appearance, Community, About) with
/// an eyebrow over each group, coloured leading icon chips and chevrons.
///
/// The screen listens to the theme controller only; the appearance pills are
/// the one thing on it that changes, and a theme or locale switch rebuilds the
/// whole app anyway.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeController theme = NovaScope.of(context).theme;
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  NovaSpace.lg, NovaSpace.lg, NovaSpace.lg, NovaSpace.xxl),
              children: <Widget>[
                Text(s.navSettings,
                    style: text.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: NovaSpace.xl),

                _Section(
                  label: s.setGeneral,
                  child: NovaCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _NavRow(
                          icon: Icons.alt_route_rounded,
                          color: nova.violet,
                          title: s.setRouting,
                          subtitle: s.setRoutingSub,
                          onTap: () => _push(context, const RoutingScreen()),
                        ),
                        _div(nova.border),
                        _NavRow(
                          icon: Icons.radar_rounded,
                          color: nova.cyan,
                          title: s.navRadar,
                          subtitle: s.setRadarSub,
                          onTap: () => _push(context, const RadarScreen()),
                        ),
                        _div(nova.border),
                        _NavRow(
                          icon: Icons.cloud_rounded,
                          color: nova.indigo,
                          title: s.setCloudflare,
                          subtitle: s.setCloudflareSub,
                          onTap: () =>
                              _push(context, const CloudflareScreen()),
                        ),
                        _div(nova.border),
                        _NavRow(
                          icon: Icons.hub_rounded,
                          color: nova.info,
                          title: s.setRelay,
                          subtitle: s.setRelaySub,
                          onTap: () => _push(context, const RelayScreen()),
                        ),
                        _div(nova.border),
                        _NavRow(
                          icon: Icons.terminal_rounded,
                          color: nova.success,
                          title: s.logsTitle,
                          subtitle: s.logsSubtitle,
                          onTap: () => _push(context, const LogScreen()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.xl),

                _Section(
                  label: s.setAppearance,
                  child: NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _Choice(
                          label: s.theme,
                          options: <Widget>[
                            _PillTarget(
                              selected: theme.themeMode == ThemeMode.system,
                              onTap: () =>
                                  theme.setThemeMode(ThemeMode.system),
                              child: NovaPill(
                                label: s.modeSystem,
                                icon: Icons.brightness_auto_rounded,
                                selected: theme.themeMode == ThemeMode.system,
                                onTap: () =>
                                    theme.setThemeMode(ThemeMode.system),
                              ),
                            ),
                            _PillTarget(
                              selected: theme.themeMode == ThemeMode.dark,
                              onTap: () => theme.setThemeMode(ThemeMode.dark),
                              child: NovaPill(
                                label: s.modeDark,
                                icon: Icons.dark_mode_rounded,
                                selected: theme.themeMode == ThemeMode.dark,
                                onTap: () =>
                                    theme.setThemeMode(ThemeMode.dark),
                              ),
                            ),
                            _PillTarget(
                              selected: theme.themeMode == ThemeMode.light,
                              onTap: () =>
                                  theme.setThemeMode(ThemeMode.light),
                              child: NovaPill(
                                label: s.modeLight,
                                icon: Icons.light_mode_rounded,
                                selected: theme.themeMode == ThemeMode.light,
                                onTap: () =>
                                    theme.setThemeMode(ThemeMode.light),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: NovaSpace.md),
                          child: Divider(height: 1, color: nova.border),
                        ),
                        _Choice(
                          label: s.language,
                          options: <Widget>[
                            _PillTarget(
                              selected: !theme.isFarsi,
                              onTap: () =>
                                  theme.setLocale(const Locale('en')),
                              child: NovaPill(
                                label: 'English',
                                selected: !theme.isFarsi,
                                onTap: () =>
                                    theme.setLocale(const Locale('en')),
                              ),
                            ),
                            _PillTarget(
                              selected: theme.isFarsi,
                              onTap: () =>
                                  theme.setLocale(const Locale('fa')),
                              child: NovaPill(
                                label: 'فارسی',
                                selected: theme.isFarsi,
                                onTap: () =>
                                    theme.setLocale(const Locale('fa')),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.xl),

                _Section(
                  label: s.setCommunity,
                  child: NovaCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _LinkTile(
                          icon: Icons.language_rounded,
                          title: 'novaproxy.online',
                          url: 'https://novaproxy.online/',
                        ),
                        _div(nova.border),
                        _LinkTile(
                          icon: Icons.send_rounded,
                          title: 'Telegram - @irnova_proxy',
                          url: 'https://t.me/irnova_proxy',
                        ),
                        _div(nova.border),
                        _LinkTile(
                          icon: Icons.camera_alt_rounded,
                          title: 'Instagram - @irnova_proxy',
                          url: 'https://instagram.com/irnova_proxy',
                        ),
                        _div(nova.border),
                        _LinkTile(
                          icon: Icons.code_rounded,
                          title: 'GitHub - IRNova',
                          url: 'https://github.com/IRNova',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.xxl),

                // About: the mark, the name, and the exact build, so a tester
                // can read the version off a screenshot.
                Center(
                  child: Column(
                    children: <Widget>[
                      const NovaLogo(size: 44),
                      const SizedBox(height: NovaSpace.sm),
                      Text('Nova',
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('v$kNovaVersion ($kNovaBuild)',
                          style: text.labelSmall?.copyWith(
                            color: nova.muted,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures()
                            ],
                          )),
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

  static Widget _div(Color c) =>
      Divider(height: 1, color: c, indent: NovaSpace.lg + 32 + NovaSpace.md);

  static void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }
}

/// A group: an eyebrow over the card. The eyebrow is uppercased and tracked in
/// Latin, plain in Farsi (see [NovaEyebrow]).
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(
              start: NovaSpace.xs, bottom: NovaSpace.sm),
          child: NovaEyebrow(label),
        ),
        child,
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: NovaSpace.lg, vertical: NovaSpace.md),
        child: Row(
          children: <Widget>[
            NovaIconChip(icon: icon, color: color, size: 32, radius: 9),
            const SizedBox(width: NovaSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: text.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: text.bodySmall?.copyWith(color: nova.muted)),
                ],
              ),
            ),
            const SizedBox(width: NovaSpace.sm),
            Icon(Icons.chevron_right_rounded, color: nova.muted),
          ],
        ),
      ),
    );
  }
}

/// A labelled set of pill options. Label above, pills wrapping below, so the
/// row cannot overflow at a narrow width or a large text scale.
class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.options});
  final String label;
  final List<Widget> options;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: nova.muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: NovaSpace.xs),
        Wrap(
          spacing: NovaSpace.xs,
          runSpacing: 0,
          children: options,
        ),
      ],
    );
  }
}

/// Hit slop and a selected state for a [NovaPill]. The pill is about 30dp
/// tall, under the touch minimum, and its state is otherwise carried by colour
/// alone; the vertical padding brings the target to 44dp without pushing the
/// pills apart visually.
class _PillTarget extends StatelessWidget {
  const _PillTarget({
    required this.child,
    required this.onTap,
    required this.selected,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: child,
          ),
        ),
      ),
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
    return InkWell(
      onTap: () async {
        final Uri uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: NovaSpace.lg, vertical: NovaSpace.md),
        child: Row(
          children: <Widget>[
            NovaIconChip(icon: icon, color: nova.cyan, size: 32, radius: 9),
            const SizedBox(width: NovaSpace.md),
            Expanded(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(width: NovaSpace.sm),
            Icon(Icons.open_in_new_rounded, size: 16, color: nova.muted),
          ],
        ),
      ),
    );
  }
}
