import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import '../../widgets/nova_segmented_tabs.dart';
import 'vps_controller.dart';

/// The SSH "install it for me" path: collect connection + auth details, then let
/// the controller SSH in, run the node installer, wait for the agent, log in,
/// and import the node. While it runs the form is replaced by a live phase
/// label and a scrolling log. All the work lives on the controller, so leaving
/// this screen never interrupts an in-flight install.
class VpsSshScreen extends StatefulWidget {
  const VpsSshScreen({super.key});

  @override
  State<VpsSshScreen> createState() => _VpsSshScreenState();
}

class _VpsSshScreenState extends State<VpsSshScreen> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController(text: '22');
  final TextEditingController _user = TextEditingController(text: 'root');
  final TextEditingController _sshPass = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _adminPass = TextEditingController();
  final TextEditingController _domain = TextEditingController();
  final ScrollController _logScroll = ScrollController();

  bool _authIsKey = false;
  bool _noDomain = false;
  bool _saveCreds = false;
  bool _obscureSshPass = true;
  bool _obscureAdmin = true;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _sshPass.dispose();
    _key.dispose();
    _passphrase.dispose();
    _adminPass.dispose();
    _domain.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  String _phaseLabel(NovaStrings s, VpsPhase phase) {
    switch (phase) {
      case VpsPhase.sshConnecting:
        return s.vpsPhaseSshConnecting;
      case VpsPhase.installing:
        return s.vpsPhaseInstalling;
      case VpsPhase.waitingForAgent:
        return s.vpsPhaseWaiting;
      case VpsPhase.loggingIn:
        return s.vpsPhaseLoggingIn;
      case VpsPhase.importing:
        return s.vpsPhaseImporting;
      case VpsPhase.idle:
      case VpsPhase.done:
      case VpsPhase.error:
        return s.vpsInstall;
    }
  }

  Future<void> _install(VpsController vps) async {
    final String key = _key.text.trim();
    final String passphrase = _passphrase.text;
    final String domain = _domain.text.trim();
    await vps.installViaSsh(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      user: _user.text.trim(),
      password: _authIsKey ? null : _sshPass.text,
      privateKeyPem: _authIsKey ? key : null,
      passphrase: passphrase.isEmpty ? null : passphrase,
      adminPassword: _adminPass.text,
      domain: domain.isEmpty ? null : domain,
      allowInsecure: _noDomain,
      persistCreds: _saveCreds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final VpsController vps = NovaScope.of(context).vps;
    final s = NovaStrings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.vpsSshCard)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListenableBuilder(
            listenable: vps,
            builder: (context, _) {
              final List<Widget> children;
              if (vps.phase == VpsPhase.done) {
                children = <Widget>[_VpsSuccess(vps: vps)];
              } else if (vps.isBusy) {
                children = <Widget>[_progress(context, vps, s)];
              } else {
                children = _form(context, vps, s);
              }
              return ListView(
                padding: const EdgeInsets.all(NovaSpace.xl),
                children: children,
              );
            },
          ),
        ),
      ),
    );
  }

  // ---- Progress view (while the install runs) ----
  Widget _progress(BuildContext context, VpsController vps, NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;

    // Keep the newest log line in view as lines stream in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Text(_phaseLabel(s, vps.phase),
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.lg),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(NovaSpace.md),
            decoration: BoxDecoration(
              color: nova.codeBg,
              borderRadius: NovaRadii.smR,
              border: Border.all(color: nova.border),
            ),
            child: SingleChildScrollView(
              controller: _logScroll,
              child: SelectableText(
                vps.logLines.join('\n'),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: nova.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Form view (before the install runs) ----
  List<Widget> _form(BuildContext context, VpsController vps, NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;

    return <Widget>[
      NovaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _host,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: s.vpsHost,
                hintText: s.vpsHostHint,
              ),
            ),
            const SizedBox(height: NovaSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: s.vpsPort),
                  ),
                ),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: TextField(
                    controller: _user,
                    autocorrect: false,
                    decoration: InputDecoration(labelText: s.vpsSshUser),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NovaSpace.lg),

            // Auth method toggle
            Text(s.vpsAuthMethod,
                style: text.labelMedium?.copyWith(color: nova.muted)),
            const SizedBox(height: NovaSpace.sm),
            NovaSegmentedTabs(
              segments: <NovaSegment>[
                NovaSegment(label: s.vpsAuthPassword, icon: Icons.password_rounded),
                NovaSegment(label: s.vpsAuthKey, icon: Icons.key_rounded),
              ],
              selected: _authIsKey ? 1 : 0,
              onChanged: (int i) => setState(() => _authIsKey = i == 1),
            ),
            const SizedBox(height: NovaSpace.md),

            if (!_authIsKey)
              TextField(
                controller: _sshPass,
                obscureText: _obscureSshPass,
                decoration: InputDecoration(
                  labelText: s.vpsSshPassword,
                  suffixIcon: _obscureToggle(
                    context,
                    _obscureSshPass,
                    () => setState(
                        () => _obscureSshPass = !_obscureSshPass),
                  ),
                ),
              )
            else ...<Widget>[
              TextField(
                controller: _key,
                minLines: 4,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: s.vpsPrivateKey,
                  hintText: s.vpsPrivateKeyHint,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              TextField(
                controller: _passphrase,
                obscureText: true,
                decoration: InputDecoration(labelText: s.vpsPassphrase),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: NovaSpace.lg),

      // Panel setup
      NovaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _adminPass,
              obscureText: _obscureAdmin,
              decoration: InputDecoration(
                labelText: s.vpsSetAdminPassword,
                helperText: s.vpsSetAdminPasswordSub,
                helperMaxLines: 2,
                suffixIcon: _obscureToggle(
                  context,
                  _obscureAdmin,
                  () => setState(() => _obscureAdmin = !_obscureAdmin),
                ),
              ),
            ),
            const SizedBox(height: NovaSpace.md),
            TextField(
              controller: _domain,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: s.vpsDomainOptional),
            ),
            const SizedBox(height: NovaSpace.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _noDomain,
              onChanged: (bool v) => setState(() => _noDomain = v),
              title: Text(s.vpsNoDomain, style: text.bodyMedium),
              subtitle: Text(s.vpsNoDomainSub,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _saveCreds,
              onChanged: (bool? v) =>
                  setState(() => _saveCreds = v ?? false),
              title: Text(s.vpsSaveCreds, style: text.bodyMedium),
            ),
          ],
        ),
      ),
      const SizedBox(height: NovaSpace.md),

      // Warning
      NovaCard(
        padding: const EdgeInsets.all(NovaSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline_rounded, color: nova.muted, size: 18),
            const SizedBox(width: NovaSpace.sm),
            Expanded(
              child: Text(s.vpsSshWarning,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ),
          ],
        ),
      ),
      const SizedBox(height: NovaSpace.lg),

      NovaButton(
        label: s.vpsInstall,
        icon: Icons.rocket_launch_rounded,
        expand: true,
        loading: vps.isBusy,
        onPressed: vps.isBusy ? null : () => _install(vps),
      ),
      if (vps.phase == VpsPhase.error) ...<Widget>[
        const SizedBox(height: NovaSpace.lg),
        _VpsErrorCard(vps: vps, onRetry: () => setState(() {})),
      ],
    ];
  }

  Widget _obscureToggle(
      BuildContext context, bool obscured, VoidCallback onTap) {
    return IconButton(
      icon: Icon(
        obscured
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        color: context.nova.muted,
        size: 20,
      ),
      onPressed: onTap,
    );
  }
}

/// The shared error card: the controller's message plus a retry that clears the
/// error so the user can edit and resubmit.
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
              Icon(Icons.check_circle_rounded,
                  color: nova.successStrong, size: 26),
              const SizedBox(width: NovaSpace.sm),
              Expanded(child: Text(s.vpsDoneTitle, style: text.titleLarge)),
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
