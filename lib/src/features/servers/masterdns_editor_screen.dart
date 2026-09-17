import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/masterdns/masterdns_config.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../theme/nova_typography.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../../widgets/nova_segmented_tabs.dart';
import '../profiles/profiles_controller.dart';

/// The resolvers a new config starts with. The same three the other client
/// fills in, so a config built here and one built there begin alike.
const List<String> kMasterDnsPublicResolvers = <String>[
  '8.8.8.8',
  '1.1.1.1',
  '208.67.222.222',
];

/// Builds a MasterDNS config by hand, edits a saved one, or finishes one that
/// was pasted.
///
/// Configs reach people in two forms: the values (a domain and a key someone
/// read out), or a block of text another client shows. So there are two
/// views, Fields and Text, over one config, and switching carries the values
/// across rather than keeping two drafts that can disagree.
///
/// Whatever the view, what is stored is the `masterdns://` link: the connect
/// path reads profiles with [MasterDnsConfig.parseLink] and nothing else.
class MasterDnsEditorScreen extends StatefulWidget {
  const MasterDnsEditorScreen({super.key, this.existing, this.initial});

  /// The profile being edited, or null when building a new one.
  final ProxyProfile? existing;

  /// Values to start a new config from, when it arrived as pasted text. The
  /// engine's own formats cannot carry resolvers, so a pasted config often has
  /// none, and the person has to see that here before it saves.
  final MasterDnsConfig? initial;

  @override
  State<MasterDnsEditorScreen> createState() => _MasterDnsEditorScreenState();
}

class _MasterDnsEditorScreenState extends State<MasterDnsEditorScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _domains = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _resolvers = TextEditingController();
  final TextEditingController _text = TextEditingController();

  MasterDnsMethod _method = MasterDnsMethod.xor;

  /// False is Fields, true is Text.
  bool _textView = false;

  /// The key is a credential, and this screen gets used on a phone held up in
  /// a room with other people in it.
  bool _keyVisible = false;

  /// Set when switching to Fields was refused because the text could not be
  /// read. Cleared by the next keystroke in the box.
  bool _textUnreadable = false;

  @override
  void initState() {
    super.initState();
    final ProxyProfile? p = widget.existing;
    MasterDnsConfig? c = widget.initial;
    if (p != null) {
      _name.text = p.name;
      c = MasterDnsConfig.parseLink(p.uri);
    } else if (c != null) {
      _name.text = c.name;
    }
    if (c == null) {
      // Only a brand new config gets the public resolvers. A saved or pasted
      // one shows what it actually has, even when that is nothing.
      if (p == null) _resolvers.text = kMasterDnsPublicResolvers.join('\n');
      return;
    }
    _fill(c);
  }

  @override
  void dispose() {
    _name.dispose();
    _domains.dispose();
    _key.dispose();
    _resolvers.dispose();
    _text.dispose();
    super.dispose();
  }

  void _fill(MasterDnsConfig c) {
    _domains.text = c.domains.join('\n');
    _key.text = c.key;
    _method = c.method;
    _resolvers.text = c.resolvers.join('\n');
  }

  static List<String> _split(String s) => s
      .split(RegExp(r'[\n,]'))
      .map((String e) => e.trim())
      .where((String e) => e.isNotEmpty)
      .toList();

  String get _nameOrDefault {
    final String n = _name.text.trim();
    return n.isEmpty ? 'MasterDNS' : n;
  }

  MasterDnsConfig _fromFields() => MasterDnsConfig(
        domains: _split(_domains.text),
        key: _key.text.trim(),
        method: _method,
        // One per line is what the label asks for, but a comma-separated
        // paste means the same thing and is cheaper to accept than to refuse.
        resolvers: _split(_resolvers.text),
        name: _nameOrDefault,
      );

  /// The config as the current view describes it, or null when the text view
  /// holds something that is not a config.
  MasterDnsConfig? get _current {
    if (!_textView) return _fromFields();
    final MasterDnsConfig? c = MasterDnsConfig.parseText(_text.text);
    if (c == null) return null;
    return MasterDnsConfig(
        domains: c.domains,
        key: c.key,
        method: c.method,
        resolvers: c.resolvers,
        name: _nameOrDefault);
  }

  static String _pretty(MasterDnsConfig c) =>
      const JsonEncoder.withIndent('  ').convert(c.toFriendlyJson());

  void _setView(bool text) {
    if (text == _textView) return;
    if (text) {
      setState(() {
        _text.text = _pretty(_fromFields());
        _textUnreadable = false;
        _textView = true;
      });
      return;
    }
    // An empty box is the way back to the fields as they were: nothing typed
    // there means nothing to carry across.
    if (_text.text.trim().isEmpty) {
      setState(() => _textView = false);
      return;
    }
    final MasterDnsConfig? c = MasterDnsConfig.parseText(_text.text);
    if (c == null) {
      // Staying put keeps what was typed. Switching would leave it in a view
      // that is about to be overwritten the next time Text is opened.
      setState(() => _textUnreadable = true);
      return;
    }
    setState(() {
      _fill(c);
      _textView = false;
    });
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = (data?.text ?? '').trim();
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(NovaStrings.of(context).serversClipboardEmpty)));
      return;
    }
    setState(() {
      _text.text = text;
      _textUnreadable = false;
    });
  }

  void _usePublic() => setState(
      () => _resolvers.text = kMasterDnsPublicResolvers.join('\n'));

  /// Why Save is refused, in words, or null when it is not.
  String? _blocker(NovaStrings s) {
    final MasterDnsConfig? c = _current;
    if (c == null) return s.masterdnsNeedsText;
    return switch (c.problem) {
      null => null,
      'no domain' => s.masterdnsNeedsDomain,
      'no encryption key' => s.masterdnsNeedsKey,
      'no resolvers' => s.masterdnsNeedsResolvers,
      // A problem this screen has no sentence for still blocks the save. A
      // config the model calls broken is broken whether or not it is named.
      _ => s.masterdnsNeedsText,
    };
  }

  void _save() {
    final MasterDnsConfig? config = _current;
    if (config == null || config.problem != null) return;
    final ProfilesController profiles = NovaScope.of(context).profiles;
    final ProxyProfile? existing = widget.existing;
    if (existing == null) {
      profiles.add(ProxyProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: config.name,
        kind: ProxyKind.masterdns,
        uri: config.toLink(),
        updatedAt: DateTime.now(),
      ));
    } else {
      profiles.update(existing.copyWith(
        name: config.name,
        uri: config.toLink(),
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
    final String? blocker = _blocker(s);

    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null
              ? s.masterdnsTitle
              : s.masterdnsEditTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
          child: ListView(
            padding: NovaSpace.page(context, all: NovaSpace.lg),
            children: <Widget>[
              Text(s.masterdnsIntro,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
              const SizedBox(height: NovaSpace.lg),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: s.masterdnsName,
                  hintText: s.masterdnsNameHint,
                ),
              ),
              const SizedBox(height: NovaSpace.lg),
              NovaSegmentedTabs(
                segments: <NovaSegment>[
                  NovaSegment(label: s.masterdnsTabFields),
                  NovaSegment(label: s.masterdnsTabText),
                ],
                selected: _textView ? 1 : 0,
                onChanged: (int i) => _setView(i == 1),
              ),
              const SizedBox(height: NovaSpace.md),
              if (_textView)
                _textCard(s, nova, text)
              else ...<Widget>[
                _serverCard(s, nova, text),
                const SizedBox(height: NovaSpace.md),
                _resolversCard(s, nova, text),
              ],
              const SizedBox(height: NovaSpace.xl),
              NovaButton(
                label: s.save,
                icon: Icons.save_rounded,
                // A config with a problem saves and then connects to nothing,
                // and the list gives no hint why. Refusing here, with the
                // reason underneath, is the only point the reason is visible.
                onPressed: blocker == null ? _save : null,
              ),
              if (blocker != null) ...<Widget>[
                const SizedBox(height: NovaSpace.sm),
                Text(blocker,
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: nova.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverCard(NovaStrings s, NovaColors nova, TextTheme text) {
    final bool noKey = _method == MasterDnsMethod.none;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.masterdnsServer),
          const SizedBox(height: NovaSpace.md),
          _MachineField(
            controller: _domains,
            label: s.masterdnsDomain,
            hint: s.masterdnsDomainHint,
            helper: s.masterdnsDomainHelp,
            keyboardType: TextInputType.url,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: NovaSpace.md),
          // With no encryption the key means nothing to the engine, so the
          // field goes rather than sitting there as a question with no effect.
          if (!noKey) ...<Widget>[
            _MachineField(
              controller: _key,
              label: s.masterdnsKey,
              obscure: !_keyVisible,
              onChanged: (_) => setState(() {}),
              suffix: IconButton(
                tooltip: _keyVisible ? s.masterdnsKeyHide : s.masterdnsKeyShow,
                icon: Icon(_keyVisible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded),
                onPressed: () => setState(() => _keyVisible = !_keyVisible),
              ),
            ),
            const SizedBox(height: NovaSpace.md),
          ],
          Text(
            s.masterdnsMethod,
            style: text.labelLarge
                ?.copyWith(fontWeight: FontWeight.w700, color: nova.text),
          ),
          const SizedBox(height: NovaSpace.sm),
          Wrap(
            spacing: NovaSpace.sm,
            runSpacing: NovaSpace.sm,
            children: <Widget>[
              for (final MasterDnsMethod m in MasterDnsMethod.values)
                NovaPill(
                  // The engine's own names. Another client and the server's
                  // config file both use them, and a translated name could not
                  // be matched against either.
                  label: m.label,
                  selected: _method == m,
                  onTap: () => setState(() => _method = m),
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(noKey ? s.masterdnsMethodNoneSub : s.masterdnsMethodSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }

  Widget _resolversCard(NovaStrings s, NovaColors nova, TextTheme text) {
    final bool empty = _split(_resolvers.text).isEmpty;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.masterdnsResolvers),
          const SizedBox(height: NovaSpace.xs),
          Text(s.masterdnsResolversHelp,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          _MachineField(
            controller: _resolvers,
            label: s.masterdnsResolversLabel,
            hint: kMasterDnsPublicResolvers.first,
            keyboardType: TextInputType.multiline,
            minLines: 3,
            maxLines: 8,
            mono: true,
            onChanged: (_) => setState(() {}),
          ),
          // Only when there are none. A pasted engine config cannot carry
          // resolvers, so this is the state it usually arrives in, and the
          // person may not have been given any.
          if (empty) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            Text(s.masterdnsResolversEmpty,
                style: text.bodySmall?.copyWith(color: nova.muted)),
            const SizedBox(height: NovaSpace.sm),
            NovaButton(
              label: s.masterdnsResolversFill,
              icon: Icons.dns_rounded,
              variant: NovaButtonVariant.ghost,
              onPressed: _usePublic,
            ),
          ],
        ],
      ),
    );
  }

  Widget _textCard(NovaStrings s, NovaColors nova, TextTheme text) {
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: NovaEyebrow(s.masterdnsText)),
              TextButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: Text(s.masterdnsPaste),
              ),
            ],
          ),
          Text(s.masterdnsTextHelp,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          _MachineField(
            controller: _text,
            label: s.masterdnsTextLabel,
            keyboardType: TextInputType.multiline,
            minLines: 8,
            maxLines: 18,
            mono: true,
            error: _textUnreadable ? s.masterdnsTextUnreadable : null,
            onChanged: (_) => setState(() => _textUnreadable = false),
          ),
        ],
      ),
    );
  }
}

/// A field that holds something a machine reads: a domain, a key, an address
/// list, a config.
///
/// Always left to right, in Farsi too. A domain or a JSON block laid out right
/// to left moves its punctuation to the wrong end and stops looking like what
/// the person was sent. Autocorrect is off for the same reason: a phone that
/// "fixes" a key has changed the key.
///
/// A one-value field still sits on the reading edge, though. In Farsi its
/// label is on the right, and a domain pinned to the left edge under it read
/// as belonging to nothing. The code blocks stay left: JSON aligned right is
/// not readable.
///
/// It takes the darker page tone rather than the card's own surface, as the
/// Aether editor's address field does: the card fill is translucent, so an
/// input using it would disappear into its parent.
class _MachineField extends StatelessWidget {
  const _MachineField({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.error,
    this.keyboardType = TextInputType.text,
    this.minLines = 1,
    this.maxLines = 1,
    this.mono = false,
    this.obscure = false,
    this.suffix,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final String? error;
  final TextInputType keyboardType;
  final int minLines;
  final int maxLines;
  final bool mono;
  final bool obscure;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final TextStyle? monoStyle = mono
        ? const TextStyle(
            fontFamily: NovaTypography.fontMono,
            fontFamilyFallback: NovaTypography.monoFallback,
            fontSize: 13,
            height: 1.45,
          )
        : null;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      obscureText: obscure,
      // An obscured field has to be single line; Flutter asserts on anything
      // else.
      minLines: obscure ? 1 : minLines,
      maxLines: obscure ? 1 : maxLines,
      keyboardType: keyboardType,
      textDirection: TextDirection.ltr,
      textAlign: rtl && !mono ? TextAlign.right : TextAlign.left,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      style: monoStyle,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: monoStyle?.copyWith(color: nova.muted),
        helperText: helper,
        helperMaxLines: 2,
        // Muted like every other explanation on the screen. The theme's
        // default is body colour, which made this the loudest line in the card.
        helperStyle: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: nova.muted),
        errorText: error,
        errorMaxLines: 4,
        alignLabelWithHint: maxLines > 1,
        fillColor: nova.bgAlt,
        suffixIcon: suffix,
      ),
    );
  }
}
