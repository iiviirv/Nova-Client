import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/aether/aether_gateway_finder.dart';
import '../../core/proxy/aether/aether_options.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import 'aether_gateway_search.dart';

/// Builds an Aether config by hand.
///
/// An `aether://` link pasted into the add sheet already imports, so this
/// screen exists for the case with nothing to paste: choosing how the WARP
/// tunnel is built, and getting a gateway for it.
///
/// The gateway is the part worth designing. In the other client the user runs a
/// scan, waits two minutes at a bare spinner, is handed one address, and when
/// that address turns out not to carry traffic the only move is to run the
/// whole thing again. Nova uses [AetherGatewayFinder], which verifies the
/// address with a real tunnel and re-scans excluding the dead ones, and this
/// screen says which attempt it is on so a long wait is explained rather than
/// silent.
class AetherEditorScreen extends StatefulWidget {
  const AetherEditorScreen({super.key, this.search});

  /// Injected by tests. The native core cannot be loaded on a test host, so
  /// without this the scan states would have no way to be exercised at all.
  final AetherGatewaySearch? search;

  @override
  State<AetherEditorScreen> createState() => _AetherEditorScreenState();
}

class _AetherEditorScreenState extends State<AetherEditorScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _outer = TextEditingController();
  final TextEditingController _inner = TextEditingController();

  AetherMode _mode = AetherMode.masque;
  AetherTransport _transport = AetherTransport.h3;
  AetherIpMode _ip = AetherIpMode.v4;
  AetherScan _scan = AetherScan.balanced;

  /// Null is a real choice, not a missing one: it leaves the profile to the
  /// core, which picks a different default per protocol. It is the first pill.
  AetherNoize? _noize;

  bool _fragment = false;

  late final AetherGatewaySearch _search = widget.search ?? AetherCoreSearch();

  AetherSearchProgress? _progress;
  AetherFindResult? _result;
  bool _stopped = false;

  bool get _searching => _progress != null;

  @override
  void dispose() {
    _search.cancel();
    _name.dispose();
    _address.dispose();
    _outer.dispose();
    _inner.dispose();
    super.dispose();
  }

  /// Applies an option change, dropping any search in flight.
  ///
  /// A result found for HTTP/3 says nothing about the HTTP/2 config the user
  /// has just switched to, so keeping it on screen would be a stale answer to a
  /// question nobody asked.
  void _set(VoidCallback change) {
    if (_searching) _stop();
    setState(change);
  }

  void _stop() {
    _search.cancel();
    setState(() {
      _progress = null;
      _result = null;
      // Set here as well as where the cancelled run lands, because a real
      // search only notices the cancel on its next poll. Without this the
      // button would sit there doing nothing visible for half a second.
      _stopped = true;
    });
  }

  AetherOptions _options() {
    final String peer = _address.text.trim();
    final String outer = _outer.text.trim();
    final String inner = _inner.text.trim();
    final bool gool = _mode == AetherMode.gool;
    // Built rather than copied: copyWith cannot put a field back to null, and
    // null is what "let the core choose" and "no forced gateway" both are.
    return AetherOptions(
      mode: _mode,
      transport: _transport,
      ip: _ip,
      scan: _scan,
      noize: _noize,
      peer: gool || peer.isEmpty ? null : peer,
      wiwOuter: gool && outer.isNotEmpty ? outer : null,
      wiwInner: gool && inner.isNotEmpty ? inner : null,
      // The core refuses --fragment outside HTTP/2, so it is only carried where
      // it means something rather than saved and silently dropped later.
      fragment: _fragment && _mode == AetherMode.masque &&
          _transport == AetherTransport.h2,
    );
  }

  Future<void> _find() async {
    setState(() {
      _stopped = false;
      _result = null;
      _progress = const AetherSearchProgress(
          attempt: 1, verifying: false, ruledOut: 0);
    });
    AetherFindResult found;
    try {
      found = await _search.run(_options(), (AetherSearchProgress p) {
        if (mounted && _searching) setState(() => _progress = p);
      });
    } catch (e) {
      // A search runs across an FFI boundary in a UI path, so a throw here is
      // otherwise a blank screen with a spinner on it forever.
      found = AetherFindResult(
          endpoint: null,
          error: '$e',
          attempts: _progress?.attempt ?? 0,
          rejected: const <String>[]);
    }
    if (!mounted) return;
    if (_search.cancelled) {
      setState(() {
        _progress = null;
        _stopped = true;
      });
      return;
    }
    setState(() {
      _progress = null;
      _result = found;
      // A verified gateway is kept, so the config saves with an address that
      // has been proven rather than one that merely answered a probe.
      if (found.endpoint != null) _address.text = found.endpoint!;
    });
  }

  void _save() {
    final String name = _name.text.trim();
    final AetherConfig config = AetherConfig(
      options: _options(),
      name: name.isEmpty ? 'Aether' : name,
    );
    NovaScope.of(context).profiles.add(ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: config.name,
      kind: ProxyKind.aether,
      // The link is the storage format: it is what shares, what re-imports, and
      // what the node parser already reads, so nothing is held twice.
      uri: config.toLink(),
      updatedAt: DateTime.now(),
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(s.aetherTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
          child: ListView(
            padding: NovaSpace.page(context, all: NovaSpace.lg),
            children: <Widget>[
              Text(s.aetherIntro,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
              const SizedBox(height: NovaSpace.lg),

              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: s.aetherName,
                  hintText: s.aetherNameHint,
                ),
              ),
              const SizedBox(height: NovaSpace.lg),

              // Protocol, with the transport nested under it: the transport is
              // a property of MASQUE, not a peer setting, and the other two
              // modes are not carried over HTTP at all.
              _Group(
                title: s.aetherProtocol,
                description: switch (_mode) {
                  AetherMode.masque => s.aetherProtoMasqueSub,
                  AetherMode.wg => s.aetherProtoWgSub,
                  AetherMode.gool => s.aetherProtoGoolSub,
                },
                pills: <Widget>[
                  _pill(s.aetherProtoMasque, _mode == AetherMode.masque,
                      () => _set(() => _mode = AetherMode.masque)),
                  _pill(s.aetherProtoWg, _mode == AetherMode.wg,
                      () => _set(() => _mode = AetherMode.wg)),
                  _pill(s.aetherProtoGool, _mode == AetherMode.gool,
                      () => _set(() => _mode = AetherMode.gool)),
                ],
                extra: _mode != AetherMode.masque
                    ? null
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _subLabel(s.aetherTransport, text, nova),
                          const SizedBox(height: NovaSpace.sm),
                          Wrap(
                            spacing: NovaSpace.sm,
                            runSpacing: NovaSpace.sm,
                            children: <Widget>[
                              _pill(
                                  s.aetherTransportH3,
                                  _transport == AetherTransport.h3,
                                  () => _set(
                                      () => _transport = AetherTransport.h3)),
                              _pill(
                                  s.aetherTransportH2,
                                  _transport == AetherTransport.h2,
                                  () => _set(
                                      () => _transport = AetherTransport.h2)),
                            ],
                          ),
                          const SizedBox(height: NovaSpace.sm),
                          Text(
                            _transport == AetherTransport.h3
                                ? s.aetherTransportH3Sub
                                : s.aetherTransportH2Sub,
                            style:
                                text.bodySmall?.copyWith(color: nova.muted),
                          ),
                          if (_transport == AetherTransport.h2) ...<Widget>[
                            const SizedBox(height: NovaSpace.sm),
                            _Toggle(
                              title: s.aetherFragment,
                              subtitle: s.aetherFragmentSub,
                              value: _fragment,
                              onChanged: (bool v) =>
                                  _set(() => _fragment = v),
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: NovaSpace.md),

              _Group(
                title: s.aetherNoize,
                description:
                    _noize == null ? s.aetherNoizeAutoSub : s.aetherNoizeSub,
                pills: <Widget>[
                  _pill(s.aetherNoizeAuto, _noize == null,
                      () => _set(() => _noize = null)),
                  for (final AetherNoize n in AetherNoize.values)
                    _pill(_noizeLabel(n), _noize == n,
                        () => _set(() => _noize = n)),
                ],
              ),
              const SizedBox(height: NovaSpace.md),

              _Group(
                title: s.aetherIp,
                description: s.aetherIpSub,
                pills: <Widget>[
                  _pill(s.aetherIpV4, _ip == AetherIpMode.v4,
                      () => _set(() => _ip = AetherIpMode.v4)),
                  _pill(s.aetherIpV6, _ip == AetherIpMode.v6,
                      () => _set(() => _ip = AetherIpMode.v6)),
                  _pill(s.aetherIpBoth, _ip == AetherIpMode.both,
                      () => _set(() => _ip = AetherIpMode.both)),
                ],
              ),
              const SizedBox(height: NovaSpace.md),

              _gatewayCard(s, nova, text),
              const SizedBox(height: NovaSpace.xl),

              NovaButton(
                label: s.save,
                icon: Icons.save_rounded,
                // Saving mid-search would store a config the running search is
                // no longer about. Cancel is the action on offer until it ends.
                onPressed: _searching ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The gateway: where it comes from, and what happened last time we looked.
  ///
  /// This is the only card that changes while the screen is open, which is why
  /// it sits last, directly above Save.
  Widget _gatewayCard(NovaStrings s, NovaColors nova, TextTheme text) {
    final bool gool = _mode == AetherMode.gool;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.aetherGateway),
          const SizedBox(height: NovaSpace.md),
          if (gool) ...<Widget>[
            _AddressField(
              controller: _outer,
              label: s.aetherHopOuter,
              hint: s.aetherGatewayHint,
            ),
            const SizedBox(height: NovaSpace.sm),
            _AddressField(
              controller: _inner,
              label: s.aetherHopInner,
              hint: s.aetherGatewayHint,
            ),
            const SizedBox(height: NovaSpace.sm),
            Text(s.aetherHopsSub,
                style: text.bodySmall?.copyWith(color: nova.muted)),
          ] else ...<Widget>[
            _AddressField(
              controller: _address,
              label: s.aetherGatewayAddress,
              hint: s.aetherGatewayHint,
              // The status line below depends on whether this is empty, so it
              // has to repaint as the field is typed into.
              onChanged: (_) => _set(() {}),
            ),
            const SizedBox(height: NovaSpace.sm),
            _status(s, nova, text),
          ],
          const SizedBox(height: NovaSpace.md),
          _subLabel(s.aetherScanMode, text, nova),
          const SizedBox(height: NovaSpace.sm),
          Wrap(
            spacing: NovaSpace.sm,
            runSpacing: NovaSpace.sm,
            children: <Widget>[
              for (final AetherScan m in AetherScan.values)
                _pill(_scanLabel(s, m), _scan == m,
                    () => _set(() => _scan = m)),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(_scanSub(s, _scan),
              style: text.bodySmall?.copyWith(color: nova.muted)),
          if (!gool) ...<Widget>[
            const SizedBox(height: NovaSpace.md),
            if (!_search.available)
              _line(Icons.info_outline_rounded, nova.warning,
                  s.aetherCoreMissing, text)
            else if (_searching)
              NovaButton(
                label: s.aetherCancel,
                icon: Icons.close_rounded,
                variant: NovaButtonVariant.secondary,
                onPressed: _stop,
              )
            else
              NovaButton(
                label: _result?.endpoint != null
                    ? s.aetherFindAgain
                    : s.aetherFindNow,
                icon: Icons.radar_rounded,
                variant: NovaButtonVariant.secondary,
                onPressed: _find,
              ),
          ],
        ],
      ),
    );
  }

  /// One line saying what is true about the gateway right now.
  ///
  /// Every state is spelled out rather than collapsed into a spinner: an empty
  /// field, an address the user typed, a search in flight on its second
  /// address, a search that was stopped, and a search that failed are five
  /// different things.
  Widget _status(NovaStrings s, NovaColors nova, TextTheme text) {
    final AetherSearchProgress? p = _progress;
    if (p != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: NovaRadii.pillR,
            child: LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: nova.border,
              valueColor: AlwaysStoppedAnimation<Color>(nova.cyan),
            ),
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(
            p.verifying
                ? s.aetherVerifyingAt(p.attempt)
                : s.aetherScanningAt(p.attempt),
            style: text.bodySmall?.copyWith(color: nova.text),
          ),
          if (p.ruledOut > 0)
            Text(s.aetherRuledOut(p.ruledOut),
                style: text.bodySmall?.copyWith(color: nova.muted)),
        ],
      );
    }

    final AetherFindResult? r = _result;
    if (r != null && r.endpoint != null) {
      return _line(Icons.check_circle_rounded, nova.success,
          s.aetherFound(r.endpoint!), text);
    }
    if (r != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _line(Icons.error_outline_rounded, nova.danger,
              s.aetherFindFailed(r.error ?? ''), text),
          if (r.rejected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: NovaSpace.xs),
              child: Text(s.aetherRuledOut(r.rejected.length),
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ),
        ],
      );
    }
    if (_stopped) {
      return Text(s.aetherScanCancelled,
          style: text.bodySmall?.copyWith(color: nova.muted));
    }
    return Text(
      _address.text.trim().isEmpty
          ? s.aetherGatewayScanned
          : s.aetherGatewayManual,
      style: text.bodySmall?.copyWith(color: nova.muted),
    );
  }

  /// A status line: the icon carries the colour, the words do not.
  ///
  /// Warning amber and danger red are the same tokens in both themes, and on
  /// the light background they come out around 2:1 against body text, which is
  /// not readable. The rest of the app solves it the same way.
  Widget _line(IconData icon, Color color, String body, TextTheme text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(body,
                style:
                    text.bodySmall?.copyWith(color: text.bodyMedium?.color)),
          ),
        ],
      );

  Widget _pill(String label, bool selected, VoidCallback onTap) =>
      NovaPill(label: label, selected: selected, onTap: onTap);

  Widget _subLabel(String t, TextTheme text, NovaColors nova) => Text(
        t,
        style: text.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700, color: nova.text),
      );

  /// The obfuscation profiles keep the core's own names. Renaming them would
  /// break the only way a user can compare a setting here with what another
  /// client, or the core's own output, calls it.
  String _noizeLabel(AetherNoize n) => switch (n) {
        AetherNoize.off => 'off',
        AetherNoize.light => 'light',
        AetherNoize.firewall => 'firewall',
        AetherNoize.balanced => 'balanced',
        AetherNoize.gfw => 'gfw',
        AetherNoize.aggressive => 'aggressive',
      };

  String _scanLabel(NovaStrings s, AetherScan m) => switch (m) {
        AetherScan.turbo => s.aetherScanTurbo,
        AetherScan.balanced => s.aetherScanBalanced,
        AetherScan.thorough => s.aetherScanThorough,
        AetherScan.stealth => s.aetherScanStealth,
        AetherScan.ironclad => s.aetherScanIronclad,
      };

  String _scanSub(NovaStrings s, AetherScan m) => switch (m) {
        AetherScan.turbo => s.aetherScanTurboSub,
        AetherScan.balanced => s.aetherScanBalancedSub,
        AetherScan.thorough => s.aetherScanThoroughSub,
        AetherScan.stealth => s.aetherScanStealthSub,
        AetherScan.ironclad => s.aetherScanIroncladSub,
      };
}

/// A titled group of choice pills, with one line under them describing what is
/// currently selected. The same shape Settings > Routing uses for its mode row.
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.description,
    required this.pills,
    this.extra,
  });

  final String title;
  final String description;
  final List<Widget> pills;

  /// A nested choice that only belongs to one of the pills above.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(title),
          const SizedBox(height: NovaSpace.md),
          Wrap(
              spacing: NovaSpace.sm,
              runSpacing: NovaSpace.sm,
              children: pills),
          const SizedBox(height: NovaSpace.sm),
          Text(description, style: text.bodySmall?.copyWith(color: nova.muted)),
          if (extra != null) ...<Widget>[
            const SizedBox(height: NovaSpace.md),
            Divider(height: 1, color: nova.border),
            const SizedBox(height: NovaSpace.md),
            extra!,
          ],
        ],
      ),
    );
  }
}

/// An address field sitting inside a card.
///
/// It takes the darker page tone rather than the card's own surface: the card
/// fill is a translucent white, so an input using it would be invisible against
/// its own parent.
class _AddressField extends StatelessWidget {
  const _AddressField({
    required this.controller,
    required this.label,
    required this.hint,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autocorrect: false,
      keyboardType: TextInputType.url,
      textCapitalization: TextCapitalization.none,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        fillColor: nova.bgAlt,
      ),
    );
  }
}

/// A switch row with a reason under it, matching the routing screen's rules.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  style:
                      text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ],
          ),
        ),
        const SizedBox(width: NovaSpace.sm),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
