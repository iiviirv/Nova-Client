import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import 'vps_controller.dart';

/// The manual "run it yourself" path: show the copyable one-liner the user runs
/// on their own VPS, then take the address and admin password to connect to the
/// agent they installed. The connect state lives on the controller, so leaving
/// this screen never restarts it.
class VpsManualScreen extends StatefulWidget {
  const VpsManualScreen({super.key});

  @override
  State<VpsManualScreen> createState() => _VpsManualScreenState();
}

class _VpsManualScreenState extends State<VpsManualScreen> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;
  bool _noDomain = false;
  bool _copied = false;

  @override
  void dispose() {
    _address.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _copy(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final VpsController vps = NovaScope.of(context).vps;
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final String command = novaNodeOneLiner();

    return Scaffold(
      appBar: AppBar(title: Text(s.vpsManualCard)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListenableBuilder(
            listenable: vps,
            builder: (context, _) {
              if (vps.phase == VpsPhase.done) {
                return ListView(
                  padding: const EdgeInsets.all(NovaSpace.xl),
                  children: <Widget>[_VpsSuccess(vps: vps)],
                );
              }
              return ListView(
                padding: const EdgeInsets.all(NovaSpace.xl),
                children: <Widget>[
                  // ---- Step 1: the one-liner ----
                  _SectionHeading(title: s.vpsManualStep1, sub: s.vpsManualStep1Sub),
                  const SizedBox(height: NovaSpace.md),
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(NovaSpace.md),
                          decoration: BoxDecoration(
                            color: nova.codeBg,
                            borderRadius: NovaRadii.smR,
                            border: Border.all(color: nova.border),
                          ),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectableText(
                              command,
                              maxLines: 1,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: NovaSpace.md),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: NovaButton(
                            label: _copied ? s.vpsCopied : s.vpsCopy,
                            icon: _copied
                                ? Icons.check_rounded
                                : Icons.copy_rounded,
                            variant: NovaButtonVariant.secondary,
                            onPressed: () => _copy(command),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.xl),

                  // ---- Step 2: connect to the agent ----
                  _SectionHeading(title: s.vpsManualStep2),
                  const SizedBox(height: NovaSpace.md),
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        TextField(
                          controller: _address,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: s.vpsAddress,
                            hintText: s.vpsAddressHint,
                          ),
                        ),
                        const SizedBox(height: NovaSpace.md),
                        TextField(
                          controller: _password,
                          obscureText: _obscure,
                          decoration: InputDecoration(
                            labelText: s.vpsAdminPassword,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: nova.muted,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        const SizedBox(height: NovaSpace.sm),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _noDomain,
                          onChanged: (bool v) => setState(() => _noDomain = v),
                          title: Text(s.vpsNoDomain,
                              style: Theme.of(context).textTheme.bodyMedium),
                          subtitle: Text(s.vpsNoDomainSub,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: nova.muted)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.lg),
                  NovaButton(
                    label: s.vpsConnect,
                    icon: Icons.link_rounded,
                    expand: true,
                    loading: vps.isBusy,
                    onPressed: vps.isBusy
                        ? null
                        : () async {
                            await vps.connectManual(
                              address: _address.text.trim(),
                              password: _password.text,
                              allowInsecure: _noDomain,
                            );
                          },
                  ),
                  if (vps.phase == VpsPhase.error) ...<Widget>[
                    const SizedBox(height: NovaSpace.lg),
                    _VpsErrorCard(vps: vps, onRetry: () => setState(() {})),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A section heading with an optional caption, matching the card-section rhythm
/// used across the Cloudflare and admin screens.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.sub});

  final String title;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (sub != null) ...<Widget>[
          const SizedBox(height: NovaSpace.xs),
          Text(sub!, style: text.bodySmall?.copyWith(color: nova.muted)),
        ],
      ],
    );
  }
}

/// The shared error card: the controller's message plus a retry that clears the
/// error and lets the user edit and resubmit.
class _VpsErrorCard extends StatelessWidget {
  const _VpsErrorCard({required this.vps, required this.onRetry});

  final VpsController vps;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    return NovaCard(
      borderColor: nova.danger.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: nova.danger),
              const SizedBox(width: NovaSpace.sm),
              Text(s.vpsFailed,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          if ((vps.error ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            Text(vps.error!, style: TextStyle(color: nova.muted)),
          ],
          const SizedBox(height: NovaSpace.md),
          NovaButton(
            label: s.vpsRetry,
            variant: NovaButtonVariant.secondary,
            expand: true,
            onPressed: () {
              vps.reset();
              onRetry();
            },
          ),
        ],
      ),
    );
  }
}

/// The success block: a green check, the done copy, then "Connect now" (imports
/// and connects, then pops to the root) and "Open admin" (pushes the full panel).
class _VpsSuccess extends StatelessWidget {
  const _VpsSuccess({required this.vps});

  final VpsController vps;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final s = NovaStrings.of(context);
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.check_circle_rounded, color: nova.successStrong, size: 26),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: Text(s.vpsDoneTitle, style: text.titleLarge),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(s.vpsDoneSub, style: text.bodyMedium?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.lg),
          NovaButton(
            label: s.vpsConnectNow,
            icon: Icons.bolt_rounded,
            expand: true,
            onPressed: () async {
              await vps.connectNow();
              if (context.mounted) {
                Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
              }
            },
          ),
          const SizedBox(height: NovaSpace.sm),
          NovaButton(
            label: s.vpsOpenAdmin,
            icon: Icons.tune_rounded,
            variant: NovaButtonVariant.secondary,
            expand: true,
            onPressed: () => vps.openAdmin(context),
          ),
        ],
      ),
    );
  }
}
