import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_checker.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_logo.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../logs/log_screen.dart';
import '../panel/open_panel.dart';
import '../routing/routing_screen.dart';
import 'settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/nova_semantics.dart';

/// Shown in the Settings "About" footer so a tester can confirm exactly which
/// build is running. Keep in step with `pubspec.yaml`'s `version:` on release.
// The release tag this build shipped as lives in update_checker.dart
// (kNovaReleaseTag); bump it there in step with kNovaBuild on every release.

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
    // The user's own panel address from Settings. It used to be guessed as the
    // subscription host's root, which opened a 404: a Nova Server panel lives
    // behind a secret admin path that a subscription URL does not reveal.
    final SettingsController settings = NovaScope.of(context).settings;

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
                NovaScreenHeader(title: s.navSettings),
                const SizedBox(height: NovaSpace.xl),

                _Section(
                  label: s.setGeneral,
                  child: NovaCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _PanelSettings(settings: settings),
                        _div(nova.border),
                        _NavRow(
                          icon: Icons.alt_route_rounded,
                          color: nova.violet,
                          title: s.setRouting,
                          subtitle: s.setRoutingSub,
                          onTap: () => _push(context, const RoutingScreen()),
                        ),
                        _div(nova.border),
                        // Radar, Cloudflare and Google relay were removed
                        // from Settings on the operator's request
                        // (2026-08-19): they are panel-owner tools, not
                        // something an end user should see here. The screens
                        // and controllers stay (the relay still serves
                        // subscription fetches when configured); only the
                        // entry points went.
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
                        _div(nova.border),
                        const _UpdateCheckTile(),
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

/// Panel address + dashboard shortcut toggle + an Open row. The address is the
/// user's, entered once; opening it goes through [openPanel], which embeds the
/// page where a webview exists and hands off to the system browser on
/// Windows/Linux (where `webview_flutter` has no backend and rendered a blank,
/// exit-less grey surface).
class _PanelSettings extends StatefulWidget {
  const _PanelSettings({required this.settings});
  final SettingsController settings;

  @override
  State<_PanelSettings> createState() => _PanelSettingsState();
}

class _PanelSettingsState extends State<_PanelSettings> {
  late final TextEditingController _url =
      TextEditingController(text: widget.settings.panelUrl);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (BuildContext context, _) {
        final Uri? uri = widget.settings.panelUri;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // The address is always LTR, whatever the UI language.
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onChanged: widget.settings.setPanelUrl,
                      decoration: InputDecoration(
                        labelText: s.panelUrlLabel,
                        hintText: s.panelUrlHint,
                        prefixIcon: const Icon(Icons.dashboard_rounded),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(s.panelUrlHelp,
                      style: text.bodySmall?.copyWith(color: nova.muted)),
                ],
              ),
            ),
            SwitchListTile(
              value: widget.settings.panelShortcut,
              onChanged: uri == null ? null : widget.settings.setPanelShortcut,
              secondary: Icon(Icons.space_dashboard_rounded, color: nova.cyan),
              title: Text(s.panelShortcut, style: text.bodyMedium),
              subtitle: Text(s.panelShortcutSub,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ),
            _NavRow(
              icon: Icons.open_in_new_rounded,
              color: nova.cyan,
              title: s.panelOpen,
              subtitle: uri == null ? s.panelNotSet : s.panelOpenSub,
              onTap: uri == null ? () {} : () => openPanel(context, uri),
            ),
          ],
        );
      },
    );
  }
}

/// "Check for updates": runs a real check and answers, instead of opening the
/// releases page and leaving the user to compare version numbers. Shows the
/// known-update state as a badge, so a user two releases behind sees it here
/// even before the dashboard banner (field report, 2026-08-19).
class _UpdateCheckTile extends StatefulWidget {
  const _UpdateCheckTile();

  @override
  State<_UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<_UpdateCheckTile> {
  bool _busy = false;

  Future<void> _check() async {
    if (_busy) return;
    setState(() => _busy = true);
    final NovaStrings s = NovaStrings.of(context);
    NovaUpdateCheck result;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      result = await checkForNovaUpdateNow(prefs);
    } catch (_) {
      result = NovaUpdateCheck.failed;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final String? tag = novaUpdateTag.value;
    switch (result) {
      case NovaUpdateCheck.updateAvailable:
        await showDialog<void>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: ctx.nova.bgAlt,
            shape: const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
            title: Text(s.updateFound),
            content: Text(s.updateFoundBody.replaceFirst('{v}', tag ?? '')),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(s.cancel)),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  launchUrl(Uri.parse(kNovaReleasesUrl),
                      mode: LaunchMode.externalApplication);
                },
                child: Text(s.updateOpen),
              ),
            ],
          ),
        );
      case NovaUpdateCheck.upToDate:
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(s.updateUpToDate)));
        }
      case NovaUpdateCheck.failed:
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(s.updateCheckFailed)));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    return ValueListenableBuilder<String?>(
      valueListenable: novaUpdateTag,
      builder: (BuildContext context, String? tag, _) => InkWell(
        onTap: _check,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: NovaSpace.lg, vertical: NovaSpace.md),
          child: Row(
            children: <Widget>[
              NovaIconChip(
                  icon: Icons.system_update_rounded,
                  color: tag == null ? nova.cyan : NovaSemantics.connectGreen,
                  size: 32,
                  radius: 9),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(s.updateCheck,
                        style: Theme.of(context).textTheme.bodyMedium),
                    if (tag != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(s.updateAvailableNow.replaceFirst('{v}', tag),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: NovaSemantics.connectGreen)),
                    ],
                  ],
                ),
              ),
              if (_busy)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.chevron_right_rounded, color: nova.muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
