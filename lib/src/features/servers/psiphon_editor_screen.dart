import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/psiphon/psiphon_config.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import '../profiles/profiles_controller.dart';

/// Builds a Psiphon profile, or edits one that already exists.
///
/// Every other editor in this app is about a server the user was given: an
/// address, a port, a key. Psiphon has none of that. It brings its own network
/// and finds its own way into it, so the whole profile is a name and one
/// choice, and this screen is that choice made as plainly as it can be.
///
/// The choice is how Psiphon dials out. Direct is Psiphon on its own. Through
/// Aether is one connection with two layers: Nova brings the WARP tunnel up
/// itself and sends Psiphon out through it. That is what the tester in Iran
/// asked for, because WARP is quick but comes out on an address that reads as
/// Iranian, so sanctioned services refuse it, and Psiphon on top of it keeps
/// the speed while giving an exit those services will serve.
///
/// Nothing on this screen asks the user to arrange anything first. The app has
/// one active profile at a time, so "connect Aether, then connect this" is not
/// a thing a person could do even if the screen asked for it.
///
/// What the screen does owe them is the wait. Psiphon is slow to start, up to
/// about three minutes, which is the budget the engine and the Aether core
/// both allow, and the chained mode is slower still because two layers have to
/// come up rather than one. A silent three-minute wait reads as a hang: that
/// is exactly how a healthy MASQUE search got reported as a bug, so the wait is
/// promised before it begins.
///
/// What is stored is [PsiphonConfig.linkFor], nothing else. The connect path
/// reads the mode back with [PsiphonConfig.modeFromLink].
class PsiphonEditorScreen extends StatefulWidget {
  const PsiphonEditorScreen({super.key, this.existing});

  /// The profile being edited, or null when building a new one.
  final ProxyProfile? existing;

  @override
  State<PsiphonEditorScreen> createState() => _PsiphonEditorScreenState();
}

class _PsiphonEditorScreenState extends State<PsiphonEditorScreen> {
  final TextEditingController _name = TextEditingController();

  /// Direct is the default because it is the mode that works with nothing else
  /// running. A new profile that defaults to the chained mode would be a
  /// profile most people cannot connect with on the day they make it.
  PsiphonMode _mode = PsiphonMode.direct;

  @override
  void initState() {
    super.initState();
    final ProxyProfile? p = widget.existing;
    if (p == null) return;
    _name.text = p.name;
    // A link this model does not recognise opens as direct rather than
    // refusing to open at all, which is the same call the model itself makes
    // for an unknown host.
    _mode = PsiphonConfig.modeFromLink(p.uri) ?? PsiphonMode.direct;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _nameOrDefault {
    final String n = _name.text.trim();
    return n.isEmpty ? 'Psiphon' : n;
  }

  void _save() {
    final ProfilesController profiles = NovaScope.of(context).profiles;
    final ProxyProfile? existing = widget.existing;
    // The link is the storage format, as it is for Aether and MasterDNS, so
    // the mode is held in one place rather than two that can disagree.
    final String uri = PsiphonConfig.linkFor(_mode);
    if (existing == null) {
      profiles.add(ProxyProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: _nameOrDefault,
        kind: ProxyKind.psiphon,
        uri: uri,
        updatedAt: DateTime.now(),
      ));
    } else {
      profiles.update(existing.copyWith(
        name: _nameOrDefault,
        uri: uri,
        updatedAt: DateTime.now(),
      ));
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
          title: Text(
              widget.existing == null ? s.psiphonTitle : s.psiphonEditTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
          child: ListView(
            padding: NovaSpace.page(context, all: NovaSpace.lg),
            children: <Widget>[
              Text(s.psiphonIntro,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
              const SizedBox(height: NovaSpace.lg),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: s.psiphonName,
                  hintText: s.psiphonNameHint,
                ),
              ),
              const SizedBox(height: NovaSpace.lg),
              _modeCard(s, nova, text),
              const SizedBox(height: NovaSpace.md),
              // The wait belongs to both modes, so it sits under the choice
              // rather than being repeated inside each option.
              _slowNote(s, nova, text),
              const SizedBox(height: NovaSpace.xl),
              NovaButton(
                label: s.save,
                icon: Icons.save_rounded,
                // Always allowed. There is nothing here that can be missing:
                // a mode is always set and the name falls back. Refusing to
                // save a chained profile while no tunnel exists would block a
                // profile that is perfectly good the moment one is built, so
                // the option says that instead.
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeCard(NovaStrings s, NovaColors nova, TextTheme text) {
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.psiphonMode),
          const SizedBox(height: NovaSpace.md),
          _ModeTile(
            title: s.psiphonDirect,
            body: s.psiphonDirectSub,
            selected: _mode == PsiphonMode.direct,
            onTap: () => setState(() => _mode = PsiphonMode.direct),
          ),
          const SizedBox(height: NovaSpace.sm),
          _ModeTile(
            title: s.psiphonAether,
            body: s.psiphonAetherSub,
            // What this mode costs, next to what it buys. The cost is time,
            // and it belongs in the option rather than in the note below,
            // which is about Psiphon itself and is true of both modes.
            note: s.psiphonAetherSlower,
            selected: _mode == PsiphonMode.throughAether,
            onTap: () => setState(() => _mode = PsiphonMode.throughAether),
          ),
        ],
      ),
    );
  }

  /// How long the first connect takes, said before it is waited through.
  ///
  /// The icon carries the colour and the words do not, the way the Aether
  /// editor's status lines do: warning amber on the light background comes out
  /// around 2:1 against body text, which is not readable.
  Widget _slowNote(NovaStrings s, NovaColors nova, TextTheme text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: nova.info.withValues(alpha: 0.10),
        borderRadius: NovaRadii.smR,
        border: Border.all(color: nova.info.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.hourglass_top_rounded, size: 18, color: nova.info),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(s.psiphonSlow,
                style: text.bodySmall?.copyWith(color: nova.text)),
          ),
        ],
      ),
    );
  }
}

/// One of the two modes, as a row you tap.
///
/// Pills would not do here: each option needs a couple of lines of explanation
/// and one of them needs a condition attached, and a pill can carry a word.
/// The selected row takes the cyan hairline and faint tint the Servers list
/// uses for the active profile, with the radio mark as the signal that does
/// not depend on colour.
///
/// The fill is the darker page tone rather than the card's own surface: the
/// card fill is translucent, so a row using it would disappear into its parent.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    this.note,
  });

  final String title;
  final String body;

  /// The one thing about this mode a person has to come away with, or null
  /// when there is nothing.
  ///
  /// Set in body colour with an icon rather than in the muted tone the
  /// description takes, so it survives a skim: whoever reads nothing else in
  /// the option reads this line.
  final String? note;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final String? need = note;

    return Material(
      color: selected ? nova.cyan.withValues(alpha: 0.07) : nova.bgAlt,
      shape: RoundedRectangleBorder(
        borderRadius: NovaRadii.smR,
        side: BorderSide(
          color: selected ? nova.cyan.withValues(alpha: 0.5) : nova.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          checked: selected,
          inMutuallyExclusiveGroup: true,
          child: Padding(
            padding: const EdgeInsets.all(NovaSpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? nova.cyan : nova.muted,
                  ),
                ),
                const SizedBox(width: NovaSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: NovaSpace.xs),
                      Text(body,
                          style:
                              text.bodySmall?.copyWith(color: nova.muted)),
                      if (need != null) ...<Widget>[
                        const SizedBox(height: NovaSpace.sm),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Icon(Icons.schedule_rounded,
                                  size: 16, color: nova.info),
                            ),
                            const SizedBox(width: NovaSpace.xs),
                            Expanded(
                              child: Text(
                                need,
                                style: text.bodySmall
                                    ?.copyWith(color: nova.text),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
