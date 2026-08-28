import 'dart:async';
import 'dart:io' show Platform;

import '../settings/settings_controller.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/conn_info_controller.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../core/proxy/subscription.dart';
import '../../core/update/update_checker.dart';
import '../../core/util/format.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_connect_orb.dart';
import '../../widgets/nova_scope.dart';
import '../../widgets/nova_segmented_tabs.dart';
import '../cloudflare/cloudflare_controller.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../cloudflare/deploy_screen.dart';
import '../profiles/profiles_controller.dart';
import '../radar/radar_screen.dart';
import '../panel/open_panel.dart';
import '../servers/node_list_screen.dart';
import '../servers/servers_body.dart';
import '../tuner/fix_connection_screen.dart';

/// The home screen: a Summary/Configs segmented header, a Cloudflare status
/// line, the connect orb with a live uptime timer, one connection panel (exit
/// country, IP, ping and live throughput), the active config card, and a
/// tools strip.
///
/// Rebuilds are scoped on purpose. The proxy controller notifies once a second
/// while connected (traffic samples), so nothing above the hero listens to it:
/// the header, tabs and Cloudflare line only rebuild for their own reasons, and
/// each block below listens to exactly the controllers it reads.
/// Temporarily hidden from the dashboard pending a product decision, kept fully
/// wired so re-enabling is a one-line flip. Mutable (not `const`) on purpose so
/// the widgets they gate still count as referenced.
bool kShowCloudflareLine = false; // the "Connect Cloudflare" row above the hero
bool kShowDashboardTools = false; // the Radar / Deploy / Panel strip

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.resetToSummary});

  /// Notified by the app shell whenever the Home tab is tapped, so the screen
  /// returns to its Summary segment.
  final Listenable? resetToSummary;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _tab = 0; // 0 = Summary, 1 = Configs

  @override
  void initState() {
    super.initState();
    widget.resetToSummary?.addListener(_backToSummary);
  }

  @override
  void didUpdateWidget(DashboardScreen old) {
    super.didUpdateWidget(old);
    if (old.resetToSummary != widget.resetToSummary) {
      old.resetToSummary?.removeListener(_backToSummary);
      widget.resetToSummary?.addListener(_backToSummary);
    }
  }

  @override
  void dispose() {
    widget.resetToSummary?.removeListener(_backToSummary);
    super.dispose();
  }

  void _backToSummary() {
    if (mounted && _tab != 0) setState(() => _tab = 0);
  }

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    final s = NovaStrings.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              NovaSpace.lg, NovaSpace.sm, NovaSpace.lg, NovaSpace.xl),
          children: <Widget>[
            const _HomeHeader(),
            const SizedBox(height: NovaSpace.md),
            ListenableBuilder(
              listenable: Listenable.merge(
                  <Listenable>[scope.profiles, scope.settings]),
              builder: (context, _) {
                // A third "Panel" segment when the user set a panel address and
                // turned the shortcut on in Settings. It is a destination, not a
                // view: tapping it opens the panel and the switcher stays where
                // it was, so the dashboard never shows an empty third pane.
                final Uri? panel = scope.settings.panelShortcut
                    ? scope.settings.panelUri
                    : null;
                return NovaSegmentedTabs(
                  selected: _tab,
                  onChanged: (i) {
                    if (panel != null && i == 2) {
                      openPanel(context, panel);
                      return;
                    }
                    setState(() => _tab = i);
                  },
                  segments: <NovaSegment>[
                    NovaSegment(
                        label: s.t('home.summary'), icon: Icons.home_rounded),
                    NovaSegment(
                      label: s.t('home.configs'),
                      icon: Icons.grid_view_rounded,
                      // The servers inside the selected subscription, which is
                      // what the tab now shows. It used to count profiles,
                      // which is what the Servers tab at the bottom is for.
                      badge: (scope.profiles.active?.isSubscription ?? false)
                          ? scope.profiles.active!.nodeCount
                          : scope.profiles.profiles.length,
                    ),
                    if (panel != null)
                      NovaSegment(
                          label: s.panelTab,
                          icon: Icons.dashboard_rounded),
                  ],
                );
              },
            ),
            const SizedBox(height: NovaSpace.xs),
            const _UpdateBanner(),
            if (kShowCloudflareLine) ...<Widget>[
              const _CloudflareLine(),
              const SizedBox(height: NovaSpace.sm),
            ],
            if (_tab == 0) const _SummaryView() else const _ConfigsView(),
          ],
        ),
      ),
    );
  }
}

/// The Configs segment: the servers inside the subscription that is currently
/// selected, with Auto at the top and every server under it to pin by hand.
///
/// It used to show the same profile list as the Servers tab at the bottom, so
/// the two were near-duplicates and neither got you to a server in one step.
/// Choosing WHICH subscription is a rare decision and stays in Servers;
/// choosing which server inside it is the frequent one and belongs here.
class _ConfigsView extends StatelessWidget {
  const _ConfigsView();

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final ProfilesController profiles = NovaScope.of(context).profiles;
    return ListenableBuilder(
      listenable: profiles,
      builder: (BuildContext context, _) {
        final ProxyProfile? active = profiles.active;
        // Nothing chosen yet: the profile list is the only useful thing to
        // show, and it carries the "add a subscription" affordances.
        if (active == null) return const ServersBody(compact: true);
        if (!active.isSubscription) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(s.configsSingleNode,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.nova.muted)),
            ),
          );
        }
        return NodeListScreen(
          // Rebuild from scratch when the active subscription changes, so the
          // list is never the previous subscription's servers.
          key: ValueKey<String>(active.id),
          profileId: active.id,
          embedded: true,
        );
      },
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    return NovaScreenHeader(
      title: s.t('home.title'),
      subtitle: s.t('home.subtitle'),
    );
  }
}

/// Cloudflare status as a quiet, borderless line rather than another boxed
/// card: it is a secondary status, and the hero below is the focal element.
/// Opens the Cloudflare hub.
class _CloudflareLine extends StatelessWidget {
  const _CloudflareLine();

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final cf = NovaScope.of(context).cloudflare;
    final text = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: cf,
      builder: (context, _) {
        final bool connected = cf.phase == CfPhase.connected;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: NovaRadii.smR,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CloudflareScreen()),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: NovaSpace.sm, vertical: NovaSpace.md),
              child: Row(
                children: <Widget>[
                  Icon(Icons.cloud_rounded,
                      size: 16,
                      color: connected ? NovaSemantics.successGreen : nova.muted),
                  const SizedBox(width: NovaSpace.sm),
                  Expanded(
                    child: connected
                        ? Text.rich(
                            TextSpan(children: <InlineSpan>[
                              TextSpan(
                                text: '${s.cfConnectedTo} ',
                                style: text.labelMedium
                                    ?.copyWith(color: nova.muted),
                              ),
                              TextSpan(
                                text: cf.accountName.isEmpty
                                    ? s.setCloudflare
                                    : cf.accountName,
                                style: text.labelMedium?.copyWith(
                                  color: nova.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            s.cfConnect,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              color: nova.muted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: nova.muted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A quiet "update available" prompt, shown only when the daily check found a
/// newer release than this build. Tapping it opens the releases page. Driven by
/// the global [novaUpdateTag] so it needs no controller wiring.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return ValueListenableBuilder<String?>(
      valueListenable: novaUpdateTag,
      builder: (context, tag, _) {
        if (tag == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: NovaSpace.sm),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: NovaRadii.cardR,
              onTap: () => launchUrl(Uri.parse(kNovaReleasesUrl),
                  mode: LaunchMode.externalApplication),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: NovaSpace.md, vertical: NovaSpace.md),
                decoration: BoxDecoration(
                  borderRadius: NovaRadii.cardR,
                  color: nova.surface,
                  border: Border.all(color: nova.border),
                ),
                child: Row(
                  children: <Widget>[
                    NovaIconChip(
                      icon: Icons.system_update_rounded,
                      color: nova.cyan,
                      size: 30,
                      radius: 9,
                    ),
                    const SizedBox(width: NovaSpace.md),
                    Expanded(
                      child: Text(
                        '${s.updateAvailable} ($tag)',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: NovaSpace.sm),
                    Text(s.updateGet,
                        style: text.labelMedium?.copyWith(
                            color: nova.cyan, fontWeight: FontWeight.w700)),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: nova.cyan),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Summary tab. A plain column of independently listening blocks, so a
/// traffic sample repaints the hero and the connection panel and nothing else.
class _SummaryView extends StatelessWidget {
  const _SummaryView();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _ProfileSync(),
        const SizedBox(height: NovaSpace.sm),
        // The gap under the hero belongs to the hero: it closes up along with
        // everything else when the hero folds into its connected shape.
        const _ConnectHero(),
        const _ConnectionPanel(),
        const _ProxyModeCard(),
        const _ConfigCard(),
        const _TunModeCard(),
        if (kShowDashboardTools) ...<Widget>[
          const SizedBox(height: NovaSpace.md),
          const _ToolsStrip(),
        ],
      ],
    );
  }
}

/// The connection mode, on the dashboard rather than three taps into Settings.
///
/// Tester report: "you move a finger in the app and it asks for a password".
/// Whole-device mode needs administrator approval on every connect, because
/// creating the tunnel device does. That is a fair price when someone wants
/// every app covered, and a bad one when they only want a browser to work, so
/// the choice belongs where the connect button is instead of buried in routing
/// settings. Desktop only: a phone's VPN permission is granted once and never
/// asked again, so there is nothing to spare anyone there.
///
/// Switching while connected reconnects, because the mode is decided when the
/// core starts. A toggle that silently did nothing until the next connect would
/// be worse than no toggle.
class _TunModeCard extends StatelessWidget {
  const _TunModeCard();

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) return const SizedBox.shrink();
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.settings, scope.proxy]),
      builder: (context, _) {
        final NovaStrings s = NovaStrings.of(context);
        final nova = context.nova;
        final TextTheme text = Theme.of(context).textTheme;
        final SettingsController settings = scope.settings;
        final bool on = settings.tunMode;
        return Padding(
          padding: const EdgeInsets.only(top: NovaSpace.md),
          child: NovaCard(
            child: Row(
              children: <Widget>[
                NovaIconChip(
                    icon: Icons.devices_rounded,
                    color: on ? nova.cyan : nova.muted),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(s.routeTun,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(on ? s.dashTunOn : s.dashTunOff,
                          style: text.bodySmall?.copyWith(color: nova.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: NovaSpace.sm),
                Switch(
                  value: on,
                  onChanged: (bool v) async {
                    await settings.setTunMode(v);
                    if (!scope.proxy.state.isActive) return;
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(s.dashTunApplies)));
                    }
                    await scope.proxy.reconnect();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Proxy mode (full-device tunnel off): where the proxy actually is. Field
/// report from Windows and Mac: with the tunnel off it was not clear how apps
/// reach the proxy at all. This says it plainly: the local SOCKS5/HTTP address,
/// with copy.
///
/// On desktop it also shows whether the OS system proxy points at it and offers
/// to set or clear that (macOS asks for admin approval). A phone has no such
/// setting, so there the card stops at the address, which is what you paste
/// into the one app you want to send through Nova. Hidden in TUN mode, where
/// there is nothing to point at.
class _ProxyModeCard extends StatelessWidget {
  const _ProxyModeCard();

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.proxy, scope.settings]),
      builder: (context, _) {
        final ProxyController proxy = scope.proxy;
        final int? port = proxy.localProxyPort;
        // Only in real proxy mode. Per-app routing opens the same port purely so
        // the app can ask its own tunnel where it exits, and telling someone to
        // point apps at it there would be wrong: their app list is what routes.
        if (port == null || !proxy.isProxyMode || !proxy.state.isActive) {
          return const SizedBox.shrink();
        }
        final NovaStrings s = NovaStrings.of(context);
        final nova = context.nova;
        final TextTheme text = Theme.of(context).textTheme;
        final String addr = '127.0.0.1:$port';
        final bool sys = proxy.systemProxyOn;
        // A phone has no system-proxy setting to point at this, so the button
        // and its status line are desktop only.
        final bool hasSystemProxy = !Platform.isAndroid && !Platform.isIOS;
        return Padding(
          padding: const EdgeInsets.only(bottom: NovaSpace.md),
          child: NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    NovaIconChip(
                        icon: Icons.settings_ethernet_rounded, color: nova.cyan),
                    const SizedBox(width: NovaSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(s.proxyModeTitle,
                              style: text.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(s.proxyModeLocal,
                              style: text.bodySmall?.copyWith(color: nova.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NovaSpace.sm),
                // The address on its own line, one tap to copy.
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: addr));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${s.proxyModeCopied}: $addr')));
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: nova.bgAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: nova.border),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(addr,
                              textDirection: TextDirection.ltr,
                              style: text.titleSmall?.copyWith(
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures()
                                  ],
                                  fontWeight: FontWeight.w700)),
                        ),
                        Icon(Icons.copy_rounded, size: 16, color: nova.muted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.sm),
                Text(s.proxyModeHint,
                    style: text.bodySmall?.copyWith(color: nova.muted)),
                if (hasSystemProxy) ...<Widget>[
                const SizedBox(height: NovaSpace.sm),
                Row(
                  children: <Widget>[
                    Icon(
                      sys ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                      size: 18,
                      color: sys ? NovaSemantics.connectGreen : nova.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(sys ? s.proxyModeSysOn : s.proxyModeSysOff,
                          style: text.bodySmall),
                    ),
                  ],
                ),
                const SizedBox(height: NovaSpace.sm),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: NovaButton(
                    label: sys ? s.proxyModeClearSys : s.proxyModeSetSys,
                    variant: NovaButtonVariant.secondary,
                    onPressed: () async {
                      final bool ok = await proxy.setSystemProxy(!sys);
                      if (!context.mounted) return;
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(s.proxyModeSetFailed)));
                      }
                    },
                  ),
                ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Keeps the proxy's selected profile in sync with the active profile. Renders
/// nothing; it exists so the sync runs from a builder that listens to exactly
/// the two controllers involved.
class _ProfileSync extends StatelessWidget {
  const _ProfileSync();

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.proxy, scope.profiles]),
      builder: (context, _) {
        final proxy = scope.proxy;
        final active = scope.profiles.active;
        if (proxy.activeProfile?.id != active?.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            proxy.selectProfile(active);
          });
        }
        return const SizedBox.shrink();
      },
    );
  }
}

/// How long the hero takes to fold into (or out of) its connected shape. The
/// orb runs its own half of the move on the same clock, so the ring, the mark
/// and the text under it settle together.
const Duration _kFold = Duration(milliseconds: 240);

/// The centered connect hero: a single status pill, the orb, and a state
/// headline + subtitle. The connect action is the one thing this screen is
/// for, so it owns the middle of the screen and the most contrast.
class _ConnectHero extends StatelessWidget {
  const _ConnectHero();

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      // connInfo is included so the "Verifying / Secure" subtitle flips the
      // moment a probe confirms traffic is actually getting through.
      listenable: Listenable.merge(
          <Listenable>[scope.proxy, scope.profiles, scope.connInfo]),
      builder: (context, _) => _ConnectHeroBody(
        proxy: scope.proxy,
        hasProfile: scope.profiles.active != null,
        reachable: scope.connInfo.info.reachable,
      ),
    );
  }
}

class _ConnectHeroBody extends StatelessWidget {
  const _ConnectHeroBody({
    required this.proxy,
    required this.hasProfile,
    required this.reachable,
  });

  final ProxyController proxy;
  final bool hasProfile;

  /// Honest reachability: the tunnel can report "connected" while a dead exit
  /// (or an urltest that hasn't settled on a live node yet) carries no traffic.
  /// Until a probe actually gets through we say "Verifying", not "Secure", so
  /// a green orb never lies about a working connection.
  final bool reachable;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final text = Theme.of(context).textTheme;
    final ProxyConnectionState state = proxy.state;
    final bool connected = state == ProxyConnectionState.connected;

    // Status pill: distinct colour and label per state, not just
    // active/inactive, so "Connecting" and errors read correctly.
    final (Color, String) badge = switch (state) {
      ProxyConnectionState.connected => (NovaSemantics.successGreen, s.connected),
      ProxyConnectionState.connecting ||
      ProxyConnectionState.disconnecting =>
        (NovaSemantics.amber, s.connecting),
      ProxyConnectionState.error => (nova.danger, s.dashError),
      ProxyConnectionState.disconnected => (nova.muted, s.disconnected),
    };

    // Headline + subtitle. Each state gets one line of explanation under the
    // headline; the same words never appear twice on the hero. Connected is the
    // exception: its clock and verdict move inside the ring (see below), so
    // nothing is left to print under the orb.
    Widget? headline;
    String? subtitle;
    Color subtitleColor = nova.muted;
    switch (state) {
      case ProxyConnectionState.connected:
        // Three honest levels: probe got through (Secure), still checking
        // (Verifying), or the controller gave up after its probes and one
        // rebuild (No traffic). The last one must not read as "in progress".
        if (reachable) {
          subtitle = s.dashSecure;
          subtitleColor = NovaSemantics.connectGreen;
        } else if (proxy.exitUnreachable) {
          subtitle = s.dashNoTraffic;
          subtitleColor = nova.danger;
        } else {
          subtitle = s.dashVerifying;
          subtitleColor = NovaSemantics.amber;
        }
      case ProxyConnectionState.connecting:
      case ProxyConnectionState.disconnecting:
        headline = _Headline(s.connecting);
      case ProxyConnectionState.error:
        headline = _Headline(s.dashError);
        subtitle = proxy.lastError;
        subtitleColor = nova.danger;
      case ProxyConnectionState.disconnected:
        headline = _Headline(s.tapToConnect);
        subtitle = s.dashNotProtectedBody;
    }

    // A live connection is when this screen gets busy: the connection panel and
    // the subscription card arrive under the hero and the three of them have to
    // share one phone screen. So the hero folds. The clock and the verdict move
    // inside the ring, the mark shrinks to seat them, and the orb itself pulls
    // in, which is what buys the cards their room without a scroll.
    final Widget? readout = connected
        ? _OrbReadout(
            since: proxy.connectedSince,
            verdict: subtitle,
            verdictColor: subtitleColor,
          )
        : null;

    // A dial with a clock in its face must not quietly shrink its own numbers:
    // when the user has asked for larger text the ring grows with it (capped)
    // rather than scaling the readout back down to fit. On a short screen the
    // dial is the first thing to give room back, so the cards under it still
    // clear the fold on a small phone.
    final double textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    // Reduced motion keeps the fade (it explains the state) and drops the
    // movement, so the layout arrives already folded.
    final Duration fold =
        MediaQuery.disableAnimationsOf(context) ? Duration.zero : _kFold;
    final double connectedSize =
        MediaQuery.sizeOf(context).height < 700 ? 132 : 152;
    final double orbSize = connected
        ? connectedSize * textScale.clamp(1.0, 1.4).toDouble()
        : 172;

    return Column(
      children: <Widget>[
        NovaStatusBadge(label: badge.$2, color: badge.$1),
        AnimatedContainer(
          duration: fold,
          curve: Curves.easeOutCubic,
          height: connected ? NovaSpace.md : NovaSpace.xl,
        ),
        NovaConnectOrb(
          state: state,
          size: orbSize,
          statusText: badge.$2,
          inlineDetail: readout,
          onTap: hasProfile || connected ? proxy.toggle : null,
        ),
        // The block under the orb collapses rather than vanishing, so the fold
        // reads as the headline moving into the ring, not a cut.
        AnimatedSize(
          duration: fold,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: headline == null
              ? const SizedBox(width: double.infinity)
              : Column(
                  children: <Widget>[
                    const SizedBox(height: NovaSpace.xl),
                    headline,
                    if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: NovaSpace.sm),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: NovaSpace.xl),
                        child: Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(
                            color: subtitleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        // When the tunnel is up but no traffic is getting through the exit, the
        // usual setup is being blocked. Offer the setup finder right here, this
        // is where users hit the wall.
        if (proxy.exitUnreachable) ...<Widget>[
          const SizedBox(height: NovaSpace.lg),
          const _FindSetupPrompt(),
        ],
        // Breathing room down to whatever the summary stacks under the hero,
        // on the same clock as the fold so it never steps out of time.
        AnimatedContainer(
          duration: fold,
          curve: Curves.easeOutCubic,
          height: connected ? NovaSpace.lg : NovaSpace.xl,
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context)
          .textTheme
          .headlineSmall
          ?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

/// What the ring carries once the connection is up: the clock, and under it the
/// one word for whether traffic is really getting through. Deliberately quiet
/// numbers, the ring around them is the loud part.
class _OrbReadout extends StatelessWidget {
  const _OrbReadout({
    required this.since,
    required this.verdict,
    required this.verdictColor,
  });

  final DateTime? since;
  final String? verdict;
  final Color verdictColor;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _UptimeText(since: since, fontSize: 24, color: kNovaOrbInk),
        if (verdict != null && verdict!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            verdict!,
            maxLines: 1,
            style: text.labelSmall?.copyWith(
              color: verdictColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

/// The uptime clock. Owns its one-second ticker so the tick rebuilds this one
/// Text and nothing around it.
class _UptimeText extends StatefulWidget {
  const _UptimeText({required this.since, this.fontSize = 44, this.color});
  final DateTime? since;

  /// Set small when the clock sits inside the ring rather than under it.
  final double fontSize;

  /// Left null to take the theme's foreground; set when the clock is printed on
  /// the orb's disc, which is dark in both themes.
  final Color? color;

  @override
  State<_UptimeText> createState() => _UptimeTextState();
}

class _UptimeTextState extends State<_UptimeText> with WidgetsBindingObserver {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No point ticking the uptime once per second while the app is in the
    // background: nobody is watching it and each tick is a rebuild. Pause it and
    // catch up with a single refresh when the user comes back.
    if (state == AppLifecycleState.resumed) {
      if (_ticker == null) {
        _startTicker();
        if (mounted) setState(() {});
      }
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      Fmt.uptime(widget.since),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.displaySmall?.copyWith(
        color: widget.color,
        fontWeight: FontWeight.w800,
        fontSize: widget.fontSize,
        height: 1.0,
        letterSpacing: -1,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Shown under the hero when the exit is unreachable: a calm, non-alarming
/// prompt that hands the user off to the setup finder.
class _FindSetupPrompt extends StatelessWidget {
  const _FindSetupPrompt();

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: nova.warning.withValues(alpha: 0.10),
        borderRadius: NovaRadii.cardR,
        border: Border.all(color: nova.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.travel_explore_rounded, size: 18, color: nova.warning),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: Text(
                  s.fixDashPrompt,
                  style: text.bodySmall
                      ?.copyWith(color: nova.muted, height: 1.35),
                ),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.md),
          NovaButton(
            label: s.fixTitle,
            icon: Icons.travel_explore_rounded,
            variant: NovaButtonVariant.secondary,
            expand: true,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const FixConnectionScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

/// One connection panel while connected: exit location, IP and ping on the
/// first line, live throughput on the second, split by a hairline. Idle it
/// renders nothing; three dashes in a box would only push the config card and
/// the tools below the fold.
class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel();

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.proxy, scope.connInfo]),
      builder: (context, _) {
        final proxy = scope.proxy;
        if (!proxy.state.isActive) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: NovaSpace.md),
          child: _ConnectionPanelBody(
            info: scope.connInfo.info,
            loading: scope.connInfo.loading,
            downBps: proxy.traffic.downlinkBps,
            upBps: proxy.traffic.uplinkBps,
          ),
        );
      },
    );
  }
}

class _ConnectionPanelBody extends StatelessWidget {
  const _ConnectionPanelBody({
    required this.info,
    required this.loading,
    required this.downBps,
    required this.upBps,
  });

  final ConnInfo info;
  final bool loading;
  final num downBps;
  final num upBps;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final String pending = loading ? '…' : '-';
    final String country =
        info.hasGeo ? (info.countryCode ?? pending) : pending;
    final String ip = info.ip ?? pending;
    final int? pingMs = info.pingMs;
    final String ping = pingMs != null ? '$pingMs ms' : pending;

    return Container(
      decoration: BoxDecoration(
        color: nova.surface,
        borderRadius: NovaRadii.heroR,
        border: Border.all(color: nova.border),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            // The two halves of the panel carry the same vertical rhythm; the
            // stat row used to sit in noticeably more air than the throughput
            // row under it.
            padding: const EdgeInsets.symmetric(
                vertical: NovaSpace.md, horizontal: NovaSpace.sm),
            child: IntrinsicHeight(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _Stat(
                      label: s.dashLocation,
                      value: country,
                      leading: info.hasGeo
                          ? NovaCountryFlag(iso2: info.countryCode, size: 15)
                          : null,
                    ),
                  ),
                  const _VRule(),
                  Expanded(child: _Stat(label: s.dashIp, value: ip)),
                  const _VRule(),
                  Expanded(
                    child: _Stat(
                      label: s.dashPing,
                      value: ping,
                      valueColor:
                          pingMs != null ? NovaSemantics.ping(pingMs) : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: nova.border),
          Padding(
            padding: const EdgeInsets.symmetric(
                vertical: NovaSpace.md, horizontal: NovaSpace.lg),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _Throughput(
                    label: s.download,
                    icon: Icons.arrow_downward_rounded,
                    color: nova.cyan,
                    value: Fmt.bps(downBps),
                  ),
                ),
                const SizedBox(width: NovaSpace.lg),
                Expanded(
                  child: _Throughput(
                    label: s.upload,
                    icon: Icons.arrow_upward_rounded,
                    color: nova.violet,
                    value: Fmt.bps(upBps),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VRule extends StatelessWidget {
  const _VRule();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: context.nova.border);
}

/// A label over a value, centred. Labels are eyebrows in Latin and plain in
/// Farsi (uppercasing and tracking are Latin treatments).
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.leading,
    this.valueColor,
  });

  final String label;
  final String value;
  final Widget? leading;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return Column(
      // Top-aligned so the three labels sit on one line even when one value
      // row is taller (the flag next to the country code).
      mainAxisAlignment: MainAxisAlignment.start,
      children: <Widget>[
        Text(
          rtl ? label : label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.labelSmall?.copyWith(
            color: nova.muted,
            fontSize: 10,
            letterSpacing: rtl ? 0 : 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (leading != null) ...<Widget>[
              leading!,
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                // Values are Latin (an IP, "14 ms"): keep them LTR in Farsi.
                textDirection: TextDirection.ltr,
                style: text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: valueColor,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures()
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A throughput reading: a small tinted arrow, the value in tabular figures,
/// and the direction as a muted caption. Weight and colour carry the hierarchy,
/// not another box.
class _Throughput extends StatelessWidget {
  const _Throughput({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
  });

  final String label;
  final IconData icon;
  final Color color;
  final String value;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        NovaIconChip(icon: icon, color: color, size: 28, radius: 8),
        const SizedBox(width: NovaSpace.sm + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures()
                  ],
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(color: nova.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The active config / server summary card. Listens to the profiles only, so
/// traffic ticks never touch it. Renders nothing when there is no profile.
class _ConfigCard extends StatelessWidget {
  const _ConfigCard();

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: scope.profiles,
      builder: (context, _) {
        final ProxyProfile? active = scope.profiles.active;
        if (active == null) return const SizedBox.shrink();
        return _ConfigCardBody(active: active);
      },
    );
  }
}

class _ConfigCardBody extends StatelessWidget {
  const _ConfigCardBody({required this.active});
  final ProxyProfile active;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final text = Theme.of(context).textTheme;
    // The card's ping is the subscription's best-node figure (what Auto would
    // pick). With a server pinned it is not the pinned server's number, so
    // it only shows in Auto mode; the pinned server's own ping lives on its
    // row in the list and in the connection panel above.
    final int? latency = active.pinnedNode == null ? active.lastLatencyMs : null;
    final SubInfo? sub = subInfoFor(active.subscriptionUrl);

    final String data;
    if (sub == null) {
      data = '∞';
    } else if (sub.total > 0) {
      data = '${Fmt.bytes(sub.used)} / ${Fmt.bytes(sub.total)}';
    } else {
      data = Fmt.bytes(sub.used);
    }
    final DateTime? e = sub?.expire;
    final String expiry = e == null
        ? '-'
        : '${e.year}-${e.month.toString().padLeft(2, '0')}-'
            '${e.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(NovaSpace.lg),
      decoration: BoxDecoration(
        color: nova.surface,
        borderRadius: NovaRadii.heroR,
        border: Border.all(color: nova.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              NovaIconChip(
                icon: active.isSubscription
                    ? Icons.cloud_sync_rounded
                    : Icons.dns_rounded,
                color: nova.indigo,
              ),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(active.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: NovaSpace.xs),
                    Wrap(
                      spacing: NovaSpace.sm,
                      runSpacing: NovaSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        NovaProtocolBadge(
                          label: active.kind.label,
                          color: nova.cyan,
                        ),
                        Text(
                          active.isSubscription
                              ? s.nodesCount(active.nodeCount)
                              : s.homeSingleConfig,
                          style: text.bodySmall?.copyWith(color: nova.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (latency != null) ...<Widget>[
                const SizedBox(width: NovaSpace.sm),
                _LatencyTag(ms: latency),
              ],
            ],
          ),
          // The live "connected via" line: which server is actually carrying
          // traffic right now, kept accurate through every auto or manual switch.
          _ActiveExitLine(active: active),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NovaSpace.sm),
            child: Divider(height: 1, color: nova.border),
          ),
          // Uptime is intentionally omitted here: the hero already shows it
          // as the big timer. This card sticks to plan info (data + expiry).
          Row(
            children: <Widget>[
              Expanded(
                child: _ConfigMetric(
                  icon: Icons.data_usage_rounded,
                  label: s.homeData,
                  value: data,
                ),
              ),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: _ConfigMetric(
                  icon: Icons.calendar_month_rounded,
                  label: s.homeExpiry,
                  value: expiry,
                ),
              ),
            ],
          ),
          // A subscription can advertise a Telegram proxy (nova.telegramProxy).
          // It is not a Nova server and nothing here connects to it: it is a
          // link Telegram itself handles, so it is offered as a shortcut and
          // nothing more. Absent from every subscription that does not publish
          // one, which is most of them.
          if (active.telegramProxy != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NovaSpace.sm),
              child: Divider(height: 1, color: nova.border),
            ),
            _TelegramProxyRow(
              url: active.telegramProxy!,
              webUrl: active.telegramProxyWeb,
            ),
          ],
        ],
      ),
    );
  }
}

/// The "open this subscription's Telegram proxy" shortcut.
///
/// Tapping hands the `tg://` link to Telegram, which adds the proxy in one
/// step. [webUrl] is tried only if nothing on the device takes that scheme,
/// which in practice means Telegram is not installed. It is never tried first:
/// it opens a web page showing a proxy the reader cannot add from there, and
/// making that the primary action was the bug the server renamed these fields
/// to stop.
///
/// Failing silently after both is deliberate. By then the only explanation is
/// that the device has no Telegram and no browser willing to take it, and an
/// error dialog on Nova's dashboard does not help with either.
class _TelegramProxyRow extends StatelessWidget {
  const _TelegramProxyRow({required this.url, this.webUrl});

  final String url;
  final String? webUrl;

  Future<bool> _launch(String? raw) async {
    if (raw == null || raw.isEmpty) return false;
    final Uri? u = Uri.tryParse(raw);
    if (u == null) return false;
    try {
      return await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _open() async {
    if (await _launch(url)) return;
    await _launch(webUrl);
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    return InkWell(
      onTap: _open,
      borderRadius: BorderRadius.circular(NovaRadii.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NovaSpace.sm),
        child: Row(
          children: <Widget>[
            Icon(Icons.send_rounded, size: 18, color: nova.indigo),
            const SizedBox(width: NovaSpace.md),
            Expanded(
              child: Text(
                s.homeTelegramProxy,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Icon(Icons.open_in_new_rounded, size: 16, color: nova.muted),
          ],
        ),
      ),
    );
  }
}

/// The server currently carrying traffic, shown only while connected. It
/// listens to the proxy state and the core's live health, so it stays accurate
/// through every switch: the auto-selector moving to a faster exit, a manual
/// pin, or a reconnect. The address comes from the core's selected node (or the
/// pinned node), so it is what is really on the wire, not a stale label.
class _ActiveExitLine extends StatelessWidget {
  const _ActiveExitLine({required this.active});
  final ProxyProfile active;

  /// The `server:port` out of a [proxyNodeKey] (`server:port:proto:path`), for a
  /// compact, honest address. Hostname and IPv4 keys split cleanly; anything odd
  /// falls back to the whole key rather than guessing.
  String _addr(String key) {
    final List<String> p = key.split(':');
    return p.length >= 2 ? '${p[0]}:${p[1]}' : key;
  }

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: scope.proxy,
      builder: (context, _) {
        if (!scope.proxy.state.isActive) return const SizedBox.shrink();
        return ValueListenableBuilder<CoreNodeHealth>(
          valueListenable: scope.proxy.coreHealth,
          builder: (context, health, __) {
            final String? key = health.selectedKey ?? active.pinnedNode;
            // Prefer the panel's own name for the server; a clean-IP node's
            // address is a meaningless Cloudflare IP. Fall back to the address
            // only when there is no name, wrapped in LRI/PDI isolates so it
            // still reads left-to-right inside Farsi RTL copy.
            final String? name = scope.proxy.exitName(key);
            final String value = name != null && name.trim().isNotEmpty
                ? name
                : key != null
                    ? '\u2066${_addr(key)}\u2069'
                    : s.homeConnectedAuto;
            return Padding(
              padding: const EdgeInsets.only(top: NovaSpace.sm),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                        color: NovaSemantics.connectGreen,
                        shape: BoxShape.circle),
                  ),
                  const SizedBox(width: NovaSpace.sm),
                  // One ellipsizing line so a long address or a large text scale
                  // can never overflow the card.
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: <InlineSpan>[
                        TextSpan(
                          text: '${s.homeConnectedVia} ',
                          style: text.labelSmall?.copyWith(color: nova.muted),
                        ),
                        TextSpan(
                          text: value,
                          style: text.labelSmall?.copyWith(
                            color: nova.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// The measured latency of the profile's best node, coloured by the shared
/// ping scale, with the dot as a second (non-colour) signal of a live reading.
class _LatencyTag extends StatelessWidget {
  const _LatencyTag({required this.ms});
  final int ms;

  @override
  Widget build(BuildContext context) {
    final Color c = NovaSemantics.ping(ms);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text('$ms ms',
            textDirection: TextDirection.ltr,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures()
                  ],
                )),
      ],
    );
  }
}

class _ConfigMetric extends StatelessWidget {
  const _ConfigMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 16, color: nova.muted),
        const SizedBox(width: NovaSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(rtl ? label : label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(
                    color: nova.muted,
                    fontSize: 10,
                    letterSpacing: rtl ? 0 : 1.0,
                  )),
              const SizedBox(height: 2),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // "138 KB / 50 GB" and dates are Latin runs; without an
                  // explicit direction the RTL paragraph reorders them.
                  textDirection: TextDirection.ltr,
                  style: text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                  )),
            ],
          ),
        ),
      ],
    );
  }
}

/// Radar / Deploy / Panel quick access as one strip of three cells split by
/// hairlines: secondary destinations, so one quiet surface rather than three
/// competing cards.
class _ToolsStrip extends StatelessWidget {
  const _ToolsStrip();

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    return Material(
      color: nova.surface,
      shape: RoundedRectangleBorder(
        borderRadius: NovaRadii.toolR,
        side: BorderSide(color: nova.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          children: <Widget>[
            Expanded(
              child: _ToolCell(
                icon: Icons.radar_rounded,
                label: s.navRadar,
                color: nova.cyan,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RadarScreen()),
                ),
              ),
            ),
            const _VRule(),
            Expanded(
              child: _ToolCell(
                icon: Icons.cloud_upload_rounded,
                label: s.toolDeploy,
                color: nova.indigo,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DeployScreen()),
                ),
              ),
            ),
            const _VRule(),
            Expanded(
              child: _ToolCell(
                icon: Icons.dashboard_rounded,
                label: s.toolPanel,
                color: nova.violet,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const CloudflareScreen()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCell extends StatelessWidget {
  const _ToolCell({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            vertical: NovaSpace.md, horizontal: NovaSpace.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            NovaIconChip(icon: icon, color: color, size: 34, radius: 10),
            const SizedBox(height: NovaSpace.sm),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
