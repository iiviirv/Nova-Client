import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/conn_info_controller.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../core/proxy/subscription.dart';
import '../../core/util/format.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_connect_orb.dart';
import '../../widgets/nova_logo.dart';
import '../../widgets/nova_scope.dart';
import '../../widgets/nova_segmented_tabs.dart';
import '../cloudflare/cloudflare_controller.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../cloudflare/deploy_screen.dart';
import '../radar/radar_screen.dart';
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
              listenable: scope.profiles,
              builder: (context, _) => NovaSegmentedTabs(
                selected: _tab,
                onChanged: (i) => setState(() => _tab = i),
                segments: <NovaSegment>[
                  NovaSegment(
                      label: s.t('home.summary'), icon: Icons.home_rounded),
                  NovaSegment(
                    label: s.t('home.configs'),
                    icon: Icons.grid_view_rounded,
                    badge: scope.profiles.profiles.length,
                  ),
                ],
              ),
            ),
            const SizedBox(height: NovaSpace.xs),
            const _CloudflareLine(),
            const SizedBox(height: NovaSpace.sm),
            if (_tab == 0)
              const _SummaryView()
            else
              const ServersBody(compact: true),
          ],
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            s.t('home.title'),
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: NovaSpace.md),
        const NovaLogo(size: 34),
      ],
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

/// The Summary tab. A plain column of independently listening blocks, so a
/// traffic sample repaints the hero and the connection panel and nothing else.
class _SummaryView extends StatelessWidget {
  const _SummaryView();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ProfileSync(),
        SizedBox(height: NovaSpace.sm),
        _ConnectHero(),
        SizedBox(height: NovaSpace.xl),
        _ConnectionPanel(),
        _ConfigCard(),
        SizedBox(height: NovaSpace.md),
        _ToolsStrip(),
      ],
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
    // headline; the same words never appear twice on the hero.
    Widget headline;
    String? subtitle;
    Color subtitleColor = nova.muted;
    switch (state) {
      case ProxyConnectionState.connected:
        headline = _UptimeText(since: proxy.connectedSince);
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

    return Column(
      children: <Widget>[
        NovaStatusBadge(label: badge.$2, color: badge.$1),
        const SizedBox(height: NovaSpace.xl),
        NovaConnectOrb(
          state: state,
          size: 172,
          statusText: badge.$2,
          onTap: hasProfile || connected ? proxy.toggle : null,
        ),
        const SizedBox(height: NovaSpace.xl),
        headline,
        if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: NovaSpace.sm),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: NovaSpace.xl),
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
        // When the tunnel is up but no traffic is getting through the exit, the
        // usual setup is being blocked. Offer the setup finder right here, this
        // is where users hit the wall.
        if (proxy.exitUnreachable) ...<Widget>[
          const SizedBox(height: NovaSpace.lg),
          const _FindSetupPrompt(),
        ],
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

/// The big uptime clock. Owns its one-second ticker so the tick rebuilds this
/// one Text and nothing around it.
class _UptimeText extends StatefulWidget {
  const _UptimeText({required this.since});
  final DateTime? since;

  @override
  State<_UptimeText> createState() => _UptimeTextState();
}

class _UptimeTextState extends State<_UptimeText> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      Fmt.uptime(widget.since),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        fontSize: 44,
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
            padding: const EdgeInsets.symmetric(
                vertical: NovaSpace.lg, horizontal: NovaSpace.sm),
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
    final int? latency = active.lastLatencyMs;
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NovaSpace.md),
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
        ],
      ),
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
