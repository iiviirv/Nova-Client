import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/aether/aether_gateway_finder.dart';
import '../../core/proxy/aether/aether_options.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_scope.dart';
import '../servers/aether_gateway_search.dart';
import '../servers/aether_naming.dart';
import '../servers/aether_search_widgets.dart';

/// One tap on the dashboard that ends in a working connection.
///
/// The ask was the shortest possible route to a WARP tunnel: not a shortcut
/// into a form, but the whole job. This builds the config, searches for a
/// gateway, proves the gateway carries traffic, saves it and connects.
///
/// Two things keep it honest. The wait is named before the tap, because the
/// search runs for minutes and a button that looks instant and then hangs
/// teaches people the feature is broken. And the card leaves once there is an
/// Aether config with a gateway on the list, so it is an offer rather than
/// furniture.
///
/// WireGuard, not MASQUE: the tester's MASQUE searches took about three
/// minutes each, and this is the path for someone who wants it over with. The
/// editor is where the other protocols live.
class AetherQuickSetupCard extends StatefulWidget {
  const AetherQuickSetupCard({super.key, this.search});

  /// Injected by tests. The native core cannot be loaded on a test host.
  final AetherGatewaySearch? search;

  /// True when this profile is an Aether config that has a gateway to dial.
  ///
  /// A config saved with no gateway is the bug this round fixed, and it cannot
  /// connect, so it does not count as one the user already has.
  static bool isWorkingAether(ProxyProfile p) {
    if (p.kind != ProxyKind.aether) return false;
    final AetherConfig? c = AetherConfig.parse(p.uri);
    return (c?.gateway ?? '').isNotEmpty;
  }

  @override
  State<AetherQuickSetupCard> createState() => _AetherQuickSetupCardState();
}

class _AetherQuickSetupCardState extends State<AetherQuickSetupCard> {
  late final AetherGatewaySearch _search = widget.search ?? AetherCoreSearch();

  AetherSearchProgress? _progress;
  String? _error;
  bool _connecting = false;

  /// The options this shortcut builds. Everything at its default, which is the
  /// point of it.
  /// MASQUE, not WireGuard.
  ///
  /// WireGuard was the first choice because it is the quickest to find. Then a
  /// tester in Iran reported it coming up and carrying nothing, while MASQUE and
  /// gool both worked, and the same WireGuard path scans, verifies and carries
  /// traffic without complaint from outside Iran.
  ///
  /// The likely reason is what each one looks like on the wire: WireGuard is
  /// raw UDP on whatever high port the scan lands on (891 and 1070 in two runs
  /// here), while MASQUE rides 443 and can fall back to HTTP/2 over TCP. A
  /// network that drops the first and allows the second produces exactly the
  /// reported result.
  ///
  /// Until that is understood, the one-tap button on the main screen has to use
  /// the protocol confirmed working for the people this is for. A shortcut that
  /// builds something that does not connect is worse than no shortcut.
  static const AetherOptions _options =
      AetherOptions(mode: AetherMode.masque);

  bool get _busy => _progress != null || _connecting;

  @override
  void dispose() {
    _search.cancel();
    super.dispose();
  }

  void _stop() {
    _search.cancel();
    setState(() => _progress = null);
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _progress =
          const AetherSearchProgress(attempt: 1, verifying: false, ruledOut: 0);
    });
    AetherFindResult found;
    try {
      found = await _search.run(_options, (AetherSearchProgress p) {
        if (mounted && _progress != null) setState(() => _progress = p);
      });
    } catch (e) {
      found = AetherFindResult(
          endpoint: null,
          error: '$e',
          attempts: 0,
          rejected: const <String>[]);
    }
    if (!mounted) return;
    if (_search.cancelled) {
      setState(() => _progress = null);
      return;
    }
    final String? endpoint = found.endpoint;
    if (endpoint == null) {
      setState(() {
        _progress = null;
        _error = found.error ?? '';
      });
      return;
    }
    // Held through the connect so the card can say what it is doing rather
    // than vanishing the instant the profile lands on the list.
    setState(() {
      _progress = null;
      _connecting = true;
    });
    await _saveAndConnect(endpoint);
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _saveAndConnect(String endpoint) async {
    final NovaScope scope = NovaScope.of(context);
    final AetherConfig config = AetherConfig(
      options: _options.copyWith(peer: endpoint),
      name: aetherAutoName(_options.mode, scope.profiles.profiles),
    );
    final ProxyProfile profile = ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: config.name,
      kind: ProxyKind.aether,
      uri: config.toLink(),
      updatedAt: DateTime.now(),
    );
    scope.profiles.add(profile);
    scope.profiles.setActive(profile.id);
    scope.proxy.selectProfile(profile);
    await scope.proxy.connect();
  }

  @override
  Widget build(BuildContext context) {
    final NovaScope scope = NovaScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.profiles, scope.proxy]),
      builder: (BuildContext context, _) {
        final bool have = scope.profiles.profiles
            .any(AetherQuickSetupCard.isWorkingAether);
        // Gone once the job is done, so the main screen does not carry a
        // permanent advertisement for something the user already has. Gone
        // while a tunnel is up for the same reason: another way out is an
        // offer worth making to someone who has not got out.
        if ((have || scope.proxy.state.isActive) && !_busy) {
          return const SizedBox.shrink();
        }
        if (!_search.available) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: NovaSpace.md),
          child: NovaCard(child: _body(context)),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final AetherSearchProgress? p = _progress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            NovaIconChip(icon: Icons.shield_moon_rounded, color: nova.cyan),
            const SizedBox(width: NovaSpace.md),
            Expanded(
              child: Text(s.aetherQuickTitle,
                  style:
                      text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: NovaSpace.md),
        if (p != null) ...<Widget>[
          AetherProgressLines(progress: p),
          const SizedBox(height: NovaSpace.md),
          NovaButton(
            label: s.aetherCancel,
            icon: Icons.close_rounded,
            variant: NovaButtonVariant.secondary,
            expand: true,
            onPressed: _stop,
          ),
          const SizedBox(height: NovaSpace.sm),
          const AetherWaitHint(),
        ] else if (_connecting) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.check_circle_rounded,
                    size: 16, color: nova.success),
              ),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: Text(s.aetherQuickConnecting,
                    style: text.bodySmall
                        ?.copyWith(color: text.bodyMedium?.color)),
              ),
            ],
          ),
        ] else ...<Widget>[
          Text(
            _error == null ? s.aetherQuickBody : s.aetherFindFailed(_error!),
            style: text.bodySmall?.copyWith(color: nova.muted, height: 1.35),
          ),
          const SizedBox(height: NovaSpace.md),
          NovaButton(
            label: _error == null ? s.aetherQuickCta : s.aetherQuickRetry,
            icon: Icons.bolt_rounded,
            expand: true,
            onPressed: _run,
          ),
          const SizedBox(height: NovaSpace.sm),
          const AetherWaitHint(),
        ],
      ],
    );
  }
}
