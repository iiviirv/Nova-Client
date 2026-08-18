import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_scope.dart';

/// The advanced editor for the SNI-block bypass recipe. It exposes the three
/// knobs the anti-DPI method actually turns, prefilled with what this profile
/// uses today (the field-tested default unless the user has already edited it):
///
///  - finalmask: the fragmentation, as the same JSON PattNG uses.
///  - fingerprint: the TLS fingerprint, including `unsafe` (Go TLS, no uTLS).
///  - cipher suites: the TLS cipher list, one per line.
///
/// Saving persists the overrides on the profile and, if this profile is the
/// live tunnel with the bypass on, reconnects so the new recipe takes effect.
/// "Reset" clears the overrides back to Nova's defaults. This is what lets a
/// tester re-tune the method when filtering changes without shipping a build.
class BypassEditorScreen extends StatefulWidget {
  const BypassEditorScreen({super.key, required this.profileId});

  final String profileId;

  @override
  State<BypassEditorScreen> createState() => _BypassEditorScreenState();
}

class _BypassEditorScreenState extends State<BypassEditorScreen> {
  /// Every fingerprint the core accepts, plus `unsafe` (Go TLS with the cipher
  /// list, no browser fingerprint) which is the bypass default.
  static const List<String> _fingerprints = <String>[
    'unsafe',
    'chrome',
    'firefox',
    'safari',
    'ios',
    'android',
    'edge',
    '360',
    'qq',
    'random',
    'randomized',
  ];

  late final TextEditingController _mask;
  late final TextEditingController _ciphers;
  String _fingerprint = 'unsafe';
  String? _maskError;

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
    _mask = TextEditingController();
    _ciphers = TextEditingController();
  }

  bool _seeded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final ProxyProfile? p = _profile;
    _mask.text = _prettyMask(p?.bypassFragmentMask ?? kBypassFragmentMask);
    _ciphers.text =
        (p?.bypassCipherSuites ?? kBypassCipherSuites).join('\n');
    _fingerprint = p?.bypassFingerprint ?? 'unsafe';
    if (!_fingerprints.contains(_fingerprint)) _fingerprint = 'unsafe';
  }

  @override
  void dispose() {
    _mask.dispose();
    _ciphers.dispose();
    super.dispose();
  }

  /// Pretty-print the finalmask JSON so it is editable, falling back to the raw
  /// string if it does not parse (so a hand-entered value is never lost).
  String _prettyMask(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  Future<void> _save() async {
    // Validate the finalmask as JSON before saving; a broken mask would make the
    // whole config fail to build, so catch it here with a clear message.
    final String maskText = _mask.text.trim();
    String? compactMask;
    if (maskText.isNotEmpty) {
      try {
        compactMask = jsonEncode(jsonDecode(maskText));
      } catch (_) {
        setState(() => _maskError = NovaStrings.of(context).bypassMaskInvalid);
        return;
      }
    }
    final List<String> ciphers = _ciphers.text
        .split(RegExp(r'[\n,]+'))
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();

    final ProxyProfile? p = _profile;
    if (p == null) return;
    // Store null when a field matches the default, so "using defaults" stays the
    // honest state and a later default change is picked up.
    final ProxyProfile updated = p.copyWith(
      bypassFingerprint: _fingerprint == 'unsafe' ? null : _fingerprint,
      bypassCipherSuites: _sameCiphers(ciphers, kBypassCipherSuites)
          ? null
          : ciphers,
      bypassFragmentMask:
          compactMask == null || compactMask == _compact(kBypassFragmentMask)
              ? null
              : compactMask,
    );
    final scope = NovaScope.of(context);
    scope.profiles.update(updated);
    if (scope.proxy.activeProfile?.id == updated.id) {
      scope.proxy.selectProfile(updated);
      if (scope.proxy.state.isActive && updated.hardenTls) {
        await scope.proxy.reconnect();
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _reset() {
    setState(() {
      _mask.text = _prettyMask(kBypassFragmentMask);
      _ciphers.text = kBypassCipherSuites.join('\n');
      _fingerprint = 'unsafe';
      _maskError = null;
    });
  }

  String _compact(String raw) {
    try {
      return jsonEncode(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  bool _sameCiphers(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.bypassEditorTitle)),
      body: ListView(
        padding: const EdgeInsets.all(NovaSpace.lg),
        children: <Widget>[
          Text(s.bypassEditorIntro,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.lg),

          // Fingerprint dropdown.
          _label(s.bypassFingerprint, text, nova.text),
          const SizedBox(height: NovaSpace.xs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: NovaSpace.md),
            decoration: BoxDecoration(
              color: nova.surface,
              borderRadius: NovaRadii.smR,
              border: Border.all(color: nova.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _fingerprint,
                isExpanded: true,
                items: <DropdownMenuItem<String>>[
                  for (final String f in _fingerprints)
                    DropdownMenuItem<String>(value: f, child: Text(f)),
                ],
                onChanged: (String? v) =>
                    setState(() => _fingerprint = v ?? 'unsafe'),
              ),
            ),
          ),
          const SizedBox(height: NovaSpace.lg),

          // Finalmask JSON.
          _label(s.bypassFinalmask, text, nova.text),
          const SizedBox(height: NovaSpace.xs),
          _MonoField(
            controller: _mask,
            minLines: 6,
            maxLines: 14,
            hint: kBypassFragmentMask,
            error: _maskError,
            onChanged: (_) {
              if (_maskError != null) setState(() => _maskError = null);
            },
          ),
          const SizedBox(height: NovaSpace.lg),

          // Cipher suites.
          _label(s.bypassCipherSuites, text, nova.text),
          const SizedBox(height: NovaSpace.xs),
          _MonoField(
            controller: _ciphers,
            minLines: 5,
            maxLines: 14,
            hint: 'TLS_AES_256_GCM_SHA384',
          ),
          const SizedBox(height: NovaSpace.xl),

          NovaButton(label: s.save, icon: Icons.save_rounded, onPressed: _save),
          const SizedBox(height: NovaSpace.sm),
          NovaButton(
            label: s.bypassResetDefaults,
            icon: Icons.restart_alt_rounded,
            variant: NovaButtonVariant.secondary,
            onPressed: _reset,
          ),
        ],
      ),
    );
  }

  Widget _label(String t, TextTheme text, Color color) => Text(
        t,
        style: text.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700, color: color),
      );
}

/// A monospace, code-style multiline field for the JSON / cipher lists.
class _MonoField extends StatelessWidget {
  const _MonoField({
    required this.controller,
    required this.minLines,
    required this.maxLines,
    this.hint,
    this.error,
    this.onChanged,
  });

  final TextEditingController controller;
  final int minLines;
  final int maxLines;
  final String? hint;
  final String? error;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      keyboardType: TextInputType.multiline,
      inputFormatters: <TextInputFormatter>[],
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontFamily: 'monospace', fontSize: 13, color: nova.muted),
        errorText: error,
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
