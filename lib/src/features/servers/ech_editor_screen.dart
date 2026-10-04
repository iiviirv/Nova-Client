import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/ech_spec.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_scope.dart';

/// The editor for the ECH lookup: where Nova fetches this profile's ECH key
/// from, written the way other clients write it (`cloudflare-ech.com+udp://1.0.0.1`),
/// so a setting that already works somewhere else can be pasted in rather than
/// translated.
///
/// Only the lookup is editable. The key itself is fetched from DNS every time
/// and never typed: a hand-entered key went stale and took the connection with
/// it, so there is deliberately no field for it here.
///
/// Saving persists the override on the profile and, if this profile is the live
/// tunnel with ECH on, reconnects so the new lookup takes effect. An empty
/// field (or one that parses back to Nova's default) stores null, which keeps
/// "using the default" the honest state and picks up a later default change.
class EchEditorScreen extends StatefulWidget {
  const EchEditorScreen({super.key, required this.profileId});

  final String profileId;

  @override
  State<EchEditorScreen> createState() => _EchEditorScreenState();
}

class _EchEditorScreenState extends State<EchEditorScreen> {
  late final TextEditingController _lookup;

  ProxyProfile? get _profile {
    final List<ProxyProfile> list = NovaScope.of(context).profiles.profiles;
    for (final ProxyProfile p in list) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _lookup = TextEditingController();
  }

  bool _seeded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    // Empty rather than prefilled with the default, so the field shows at a
    // glance whether this profile has an override. The hint carries the default.
    _lookup.text = _profile?.echConfigList ?? '';
  }

  @override
  void dispose() {
    _lookup.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String text = _lookup.text.trim();
    final EchSpec spec = EchSpec.parse(text);

    final ProxyProfile? p = _profile;
    if (p == null) return;
    // Store null when the entry is empty or means the default, so a later
    // change to Nova's default reaches this profile instead of being pinned to
    // whatever the default happened to be the day someone opened this screen.
    final bool useDefault = text.isEmpty || spec == EchSpec.fallback;
    final ProxyProfile updated = useDefault
        ? p.copyWith(clearEchConfigList: true)
        // Store the parsed text, not the raw text, so what is saved is what
        // Nova understood: the readout above the button is then the truth.
        : p.copyWith(echConfigList: spec.text);
    final scope = NovaScope.of(context);
    scope.profiles.update(updated);
    if (scope.proxy.activeProfile?.id == updated.id) {
      scope.proxy.selectProfile(updated);
      if (scope.proxy.state.isActive && updated.echSni) {
        await scope.proxy.reconnect();
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    // Parsed on every build rather than kept in a second piece of state, so the
    // readout can never disagree with the field it is explaining.
    final EchSpec spec = EchSpec.parse(_lookup.text);
    return Scaffold(
      appBar: AppBar(title: Text(s.echEditTitle)),
      body: ListView(
        padding: const EdgeInsets.all(NovaSpace.lg),
        children: <Widget>[
          Text(s.echEditIntro,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.lg),

          // The lookup, in the domain+resolver form.
          _label(s.echLookup, text, nova.text),
          const SizedBox(height: NovaSpace.xs),
          _MonoField(
            controller: _lookup,
            minLines: 1,
            // Unbounded rather than two lines: a DoH endpoint is long, and at
            // a large text size on a narrow phone a capped field cut the value
            // short instead of wrapping it.
            maxLines: null,
            keyboardType: TextInputType.url,
            hint: EchSpec.fallback.text,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: NovaSpace.lg),

          // What Nova made of it. Both halves are optional and anything it
          // cannot use falls back silently, so a typo would otherwise only
          // show up as a connection that quietly stopped using ECH.
          _label(s.echUnderstood, text, nova.text),
          const SizedBox(height: NovaSpace.xs),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: NovaSpace.md, vertical: NovaSpace.sm),
            decoration: BoxDecoration(
              color: nova.surface,
              borderRadius: NovaRadii.smR,
              border: Border.all(color: nova.border),
            ),
            // A table rather than two rows, so both values start at the same
            // x: the label column sizes to the longer of the two names and the
            // pair reads as a pair, in either language.
            child: Table(
              columnWidths: const <int, TableColumnWidth>{
                0: IntrinsicColumnWidth(),
                1: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: <TableRow>[
                _readback(s.echDomain, spec.domain, text, nova),
                _readback(s.echResolver, spec.resolver, text, nova),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.xl),

          NovaButton(label: s.save, icon: Icons.save_rounded, onPressed: _save),
        ],
      ),
    );
  }

  Widget _label(String t, TextTheme text, Color color) => Text(
        t,
        style: text.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700, color: color),
      );

  /// One line of the read-only confirmation. The value is forced left-to-right
  /// because a domain or a resolver URL reads wrong when the surrounding page
  /// is Farsi.
  TableRow _readback(
          String name, String value, TextTheme text, NovaColors nova) =>
      TableRow(
        children: <Widget>[
          Padding(
            // Directional, so the gap stays between the name and the value
            // when the page runs right to left.
            padding: const EdgeInsetsDirectional.only(
                end: NovaSpace.sm, bottom: NovaSpace.xs),
            child:
                Text(name, style: text.labelSmall?.copyWith(color: nova.muted)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: NovaSpace.xs),
            // The value reads left to right whatever the page does, but it
            // still sits next to its own name rather than at the far edge of
            // the cell, which is where a Farsi page would otherwise send it.
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Text(
                value,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.4,
                  color: nova.text,
                ),
              ),
            ),
          ),
        ],
      );
}

/// A monospace, code-style field for the lookup, matching the bypass editor's.
class _MonoField extends StatelessWidget {
  const _MonoField({
    required this.controller,
    required this.minLines,
    required this.maxLines,
    this.keyboardType = TextInputType.multiline,
    this.hint,
    this.onChanged,
  });

  final TextEditingController controller;
  final int minLines;

  /// Null lets the field grow, so a long value is never cut short.
  final int? maxLines;
  final TextInputType keyboardType;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      keyboardType: keyboardType,
      // A hostname is not prose: autocorrect and autocapitalisation on a phone
      // keyboard turn a valid lookup into a silent fallback.
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      style:
          const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            TextStyle(fontFamily: 'monospace', fontSize: 13, color: nova.muted),
        filled: true,
        fillColor: nova.surface,
        border: OutlineInputBorder(
          borderRadius: NovaRadii.smR,
          borderSide: BorderSide(color: nova.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NovaRadii.smR,
          borderSide: BorderSide(color: nova.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NovaRadii.smR,
          borderSide: BorderSide(color: NovaSemantics.connectGreen),
        ),
      ),
    );
  }
}
