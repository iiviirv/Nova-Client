import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_scope.dart';
import 'relay_client.dart';
import 'relay_controller.dart';
import 'relay_link.dart';
import 'tunnel_client.dart';
import 'tunnel_controller.dart';

/// Setup screen for the "Google relay": paste the Apps Script `/exec` URL (or a
/// self-hosted node `/relay` URL), optionally an auth key, test it end to end,
/// and enable it. When on, the app fetches its subscription and reaches the
/// panel through Google, so the config layer keeps working while the panel's
/// own domain is blocked. See [RelayGuideScreen] for the full explanation.
class RelayScreen extends StatefulWidget {
  const RelayScreen({super.key});

  @override
  State<RelayScreen> createState() => _RelayScreenState();
}

class _RelayScreenState extends State<RelayScreen> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _auth = TextEditingController();
  final TextEditingController _frontSni = TextEditingController();
  final TextEditingController _frontIp = TextEditingController();
  final TextEditingController _tunnelUrl = TextEditingController();
  final TextEditingController _tunnelKey = TextEditingController();
  final TextEditingController _tunnelPort = TextEditingController();

  bool _allowInsecure = false;
  bool _enabled = false;
  bool _frontEnabled = false;
  bool _obscure = true;
  bool _tunnelObscure = true;
  bool _testing = false;
  bool _picking = false;
  bool _tunnelBusy = false;

  RelayController get _relay => NovaScope.of(context).relay;
  TunnelController get _tunnel => NovaScope.of(context).tunnel;

  @override
  void initState() {
    super.initState();
    // Reflect the stored config once, after the first frame so NovaScope is
    // reachable. Rebuild on URL edits so the Test button enables/disables live.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final RelayController r = _relay;
      _url.text = r.execUrl;
      _auth.text = r.authKey;
      _frontSni.text = r.frontSni;
      _frontIp.text = r.frontIp;
      final TunnelController tn = _tunnel;
      _tunnelUrl.text = tn.url;
      _tunnelKey.text = tn.authKey;
      _tunnelPort.text = tn.port.toString();
      if (mounted) {
        setState(() {
          _allowInsecure = r.allowInsecure;
          _enabled = r.enabled;
          _frontEnabled = r.frontEnabled;
        });
      }
    });
    _url.addListener(_onUrlChanged);
  }

  void _onUrlChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _auth.dispose();
    _frontSni.dispose();
    _frontIp.dispose();
    _tunnelUrl.dispose();
    _tunnelKey.dispose();
    _tunnelPort.dispose();
    super.dispose();
  }

  Future<void> _saveTunnel() async {
    await _tunnel.save(
      url: _tunnelUrl.text.trim(),
      authKey: _tunnelKey.text.trim(),
      port: int.tryParse(_tunnelPort.text.trim()) ?? TunnelController.defaultPort,
    );
  }

  /// Start or stop the local SOCKS5 tunnel, persisting the config first.
  Future<void> _toggleTunnel() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _tunnelBusy = true);
    try {
      await _saveTunnel();
      if (_tunnel.running) {
        await _tunnel.stop();
        await _tunnel.save(enabled: false);
        _toast(s.relayTunnelStopped);
      } else {
        final int p = await _tunnel.start();
        await _tunnel.save(enabled: true);
        _toast('${s.relayTunnelRunning}$p');
      }
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _tunnelBusy = false);
    }
  }

  /// Prove the whole tunnel path: fetch a Google probe through the local SOCKS5.
  Future<void> _testTunnel() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _tunnelBusy = true);
    try {
      await _saveTunnel();
      await _tunnel.selfTest();
      _toast(s.relayTunnelOk);
    } on TunnelException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _tunnelBusy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _test() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _testing = true);
    try {
      await _relay.test(
        execUrl: _url.text.trim(),
        authKey: _auth.text.trim(),
        allowInsecure: _allowInsecure,
        frontEnabled: _frontEnabled,
        frontSni: _frontSni.text.trim(),
        frontIp: _frontIp.text.trim(),
      );
      _toast(s.relayTestOk);
    } on RelayException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Prove domain fronting works on its own (no relay), and toast the result.
  Future<void> _testDirect() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _testing = true);
    try {
      await _relay.testDirect(
        frontSni: _frontSni.text.trim(),
        frontIp: _frontIp.text.trim(),
      );
      _toast(s.relayFrontOk);
    } on RelayException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Race the built-in Google edge pool and drop the first live IP into the
  /// field, so the user does not have to hand-pick one.
  Future<void> _pickFront() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _picking = true);
    _toast(s.relayFrontPicking);
    try {
      final String? ip = await _relay.pickBestFrontIp();
      if (!mounted) return;
      if (ip != null) {
        setState(() => _frontIp.text = ip);
        _toast(s.relayFrontPicked);
      } else {
        _toast(s.relayFrontNone);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    final NovaStrings s = NovaStrings.of(context);
    await _relay.save(
      enabled: _enabled,
      execUrl: _url.text.trim(),
      authKey: _auth.text.trim(),
      allowInsecure: _allowInsecure,
      frontEnabled: _frontEnabled,
      frontSni: _frontSni.text.trim(),
      frontIp: _frontIp.text.trim(),
    );
    _toast(s.relaySaved);
  }

  Future<void> _remove() async {
    final NovaStrings s = NovaStrings.of(context);
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: Text(s.relayRemoveTitle),
            content: Text(s.relayRemoveBody),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(s.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(s.relayRemove,
                    style: TextStyle(color: context.nova.danger)),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _relay.clear();
    if (!mounted) return;
    setState(() {
      _url.text = '';
      _auth.text = '';
      _frontSni.text = _relay.frontSni;
      _frontIp.text = '';
      _allowInsecure = false;
      _enabled = false;
      _frontEnabled = false;
    });
    _toast(s.relayRemoved);
  }

  /// Import a `nova-relay://` link from the clipboard: fill and enable the relay
  /// (and tunnel, if the link carries one) with no hand-typing.
  Future<void> _importFromClipboard() async {
    final NovaStrings s = NovaStrings.of(context);
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final RelayLinkData? d = RelayLinkData.decode((data?.text ?? '').trim());
    if (d == null) {
      _toast(s.relayImportNone);
      return;
    }
    await _relay.applyLink(d);
    await _tunnel.applyLink(d);
    if (!mounted) return;
    setState(() {
      _url.text = _relay.execUrl;
      _auth.text = _relay.authKey;
      _frontSni.text = _relay.frontSni;
      _frontIp.text = _relay.frontIp;
      _allowInsecure = _relay.allowInsecure;
      _enabled = _relay.enabled;
      _frontEnabled = _relay.frontEnabled;
      _tunnelUrl.text = _tunnel.url;
      _tunnelKey.text = _tunnel.authKey;
      _tunnelPort.text = _tunnel.port.toString();
    });
    _toast(s.relayImportedOk);
  }

  /// Export the current setup as a `nova-relay://` link: copy it and show a QR
  /// so it can be handed to another device or user.
  Future<void> _share() async {
    final NovaStrings s = NovaStrings.of(context);
    if (_url.text.trim().isEmpty) {
      _toast(s.relayNeedUrlToShare);
      return;
    }
    final String link = RelayLinkData(
      execUrl: _url.text.trim(),
      authKey: _auth.text.trim(),
      allowInsecure: _allowInsecure,
      frontEnabled: _frontEnabled,
      frontSni: _frontSni.text.trim(),
      frontIp: _frontIp.text.trim(),
      tunnelUrl: _tunnelUrl.text.trim(),
      tunnelKey: _tunnelKey.text.trim(),
      tunnelPort: int.tryParse(_tunnelPort.text.trim()),
    ).encode();
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    _toast(s.relayLinkCopied);
    final nova = context.nova;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.relayShareTitle),
        content: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 244,
                height: 244,
                padding: const EdgeInsets.all(NovaSpace.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: NovaRadii.smR,
                ),
                child: QrImageView(
                  data: link,
                  size: 212,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              Text(s.relayShareSub,
                  style: Theme.of(ctx)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: nova.muted)),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
        ],
      ),
    );
  }

  void _openGuide() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RelayGuideScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final RelayController relay = NovaScope.of(context).relay;
    final text = Theme.of(context).textTheme;
    final bool hasUrl = _url.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.relayTitle),
        actions: <Widget>[
          IconButton(
            tooltip: s.relayHowItWorks,
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: _openGuide,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListenableBuilder(
            listenable: relay,
            builder: (BuildContext context, _) {
              final bool active = relay.active;
              final bool configured = relay.execUrl.trim().isNotEmpty;
              return ListView(
                padding: const EdgeInsets.all(NovaSpace.xl),
                children: <Widget>[
                  // ---- Header: intro + live status ----
                  Row(
                    children: <Widget>[
                      NovaIconChip(
                        icon: Icons.hub_rounded,
                        color: nova.info,
                        size: 40,
                        radius: 11,
                      ),
                      const SizedBox(width: NovaSpace.md),
                      Expanded(
                        child: Text(s.relayTitle, style: text.titleLarge),
                      ),
                      NovaStatusBadge(
                        label:
                            active ? s.relayStatusActive : s.relayStatusOff,
                        color: active ? nova.successStrong : nova.muted,
                      ),
                    ],
                  ),
                  const SizedBox(height: NovaSpace.sm),
                  Text(
                    s.relayIntro,
                    style: text.bodyMedium?.copyWith(color: nova.muted),
                  ),
                  const SizedBox(height: NovaSpace.md),

                  // ---- Import / Share the whole setup in one link ----
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: NovaButton(
                          label: s.relayImport,
                          icon: Icons.download_rounded,
                          variant: NovaButtonVariant.secondary,
                          onPressed: _importFromClipboard,
                        ),
                      ),
                      const SizedBox(width: NovaSpace.sm),
                      Expanded(
                        child: NovaButton(
                          label: s.relayShare,
                          icon: Icons.ios_share_rounded,
                          variant: NovaButtonVariant.secondary,
                          onPressed: _share,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NovaSpace.lg),

                  // ---- Form ----
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        NovaEyebrow(s.relaySection),
                        const SizedBox(height: NovaSpace.md),
                        TextField(
                          controller: _url,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: s.relayUrlLabel,
                            hintText: s.relayUrlHint,
                          ),
                        ),
                        _HelperText(s.relayUrlHelp),
                        const SizedBox(height: NovaSpace.md),
                        TextField(
                          controller: _auth,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: s.relayAuthLabel,
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
                        _HelperText(s.relayAuthHelp),
                        const SizedBox(height: NovaSpace.sm),
                        Divider(height: 1, color: nova.border),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _allowInsecure,
                          onChanged: (bool v) =>
                              setState(() => _allowInsecure = v),
                          title: Text(s.relayInsecureTitle,
                              style: text.bodyMedium),
                          subtitle: Text(s.relayInsecureSub,
                              style: text.bodySmall
                                  ?.copyWith(color: nova.muted)),
                        ),
                        Divider(height: 1, color: nova.border),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _enabled,
                          onChanged: (bool v) => setState(() => _enabled = v),
                          title: Text(s.relayEnableTitle,
                              style: text.bodyMedium),
                          subtitle: Text(s.relayEnableSub,
                              style: text.bodySmall
                                  ?.copyWith(color: nova.muted)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.md),

                  // ---- Direct (domain fronting) ----
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _frontEnabled,
                          onChanged: (bool v) =>
                              setState(() => _frontEnabled = v),
                          title:
                              Text(s.relayFrontTitle, style: text.bodyLarge),
                          subtitle: Text(s.relayFrontSub,
                              style: text.bodySmall
                                  ?.copyWith(color: nova.muted)),
                        ),
                        if (_frontEnabled) ...<Widget>[
                          const SizedBox(height: NovaSpace.sm),
                          TextField(
                            controller: _frontSni,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: InputDecoration(
                              labelText: s.relayFrontSniLabel,
                              hintText: 'www.google.com',
                            ),
                          ),
                          _HelperText(s.relayFrontSniHelp),
                          const SizedBox(height: NovaSpace.md),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: TextField(
                                  controller: _frontIp,
                                  keyboardType: TextInputType.number,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: InputDecoration(
                                    labelText: s.relayFrontIpLabel,
                                    hintText: '216.239.38.120',
                                  ),
                                ),
                              ),
                              const SizedBox(width: NovaSpace.sm),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: NovaButton(
                                  label: s.relayFrontAuto,
                                  icon: Icons.auto_awesome_rounded,
                                  variant: NovaButtonVariant.secondary,
                                  loading: _picking,
                                  onPressed: (_picking || _testing)
                                      ? null
                                      : _pickFront,
                                ),
                              ),
                            ],
                          ),
                          _HelperText(s.relayFrontIpHelp),
                          const SizedBox(height: NovaSpace.sm),
                          NovaButton(
                            label: s.relayTestDirect,
                            icon: Icons.bolt_rounded,
                            variant: NovaButtonVariant.secondary,
                            expand: true,
                            onPressed: _testing ? null : _testDirect,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.md),

                  // ---- Test ----
                  NovaButton(
                    label: _testing ? s.relayTesting : s.relayTest,
                    icon: Icons.wifi_tethering_rounded,
                    variant: NovaButtonVariant.secondary,
                    expand: true,
                    loading: _testing,
                    onPressed: (hasUrl && !_testing) ? _test : null,
                  ),
                  const SizedBox(height: NovaSpace.sm),

                  // ---- Save ----
                  NovaButton(
                    label: s.relaySave,
                    icon: Icons.check_rounded,
                    expand: true,
                    onPressed: _testing ? null : _save,
                  ),

                  // ---- Remove (only when something is stored) ----
                  if (configured) ...<Widget>[
                    const SizedBox(height: NovaSpace.sm),
                    NovaButton(
                      label: s.relayRemove,
                      icon: Icons.delete_outline_rounded,
                      variant: NovaButtonVariant.danger,
                      expand: true,
                      onPressed: _testing ? null : _remove,
                    ),
                  ],
                  const SizedBox(height: NovaSpace.lg),

                  // ---- Full tunnel (last resort) ----
                  ListenableBuilder(
                    listenable: _tunnel,
                    builder: (BuildContext context, _) {
                      final bool running = _tunnel.running;
                      return NovaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                NovaIconChip(
                                  icon: Icons.vpn_lock_rounded,
                                  color: nova.warning,
                                  size: 34,
                                  radius: 10,
                                ),
                                const SizedBox(width: NovaSpace.md),
                                Expanded(
                                  child: Text(s.relayTunnelTitle,
                                      style: text.titleMedium),
                                ),
                                NovaStatusBadge(
                                  label: running
                                      ? ':${_tunnel.port}'
                                      : s.relayStatusOff,
                                  color: running
                                      ? nova.successStrong
                                      : nova.muted,
                                ),
                              ],
                            ),
                            const SizedBox(height: NovaSpace.sm),
                            Text(s.relayTunnelSub,
                                style: text.bodySmall
                                    ?.copyWith(color: nova.muted)),
                            const SizedBox(height: NovaSpace.md),
                            TextField(
                              controller: _tunnelUrl,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: 'Tunnel exit URL',
                                hintText: 'https://your-node/tunnel',
                              ),
                            ),
                            const SizedBox(height: NovaSpace.md),
                            TextField(
                              controller: _tunnelKey,
                              obscureText: _tunnelObscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: s.relayAuthLabel,
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _tunnelObscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: nova.muted,
                                    size: 20,
                                  ),
                                  onPressed: () => setState(
                                      () => _tunnelObscure = !_tunnelObscure),
                                ),
                              ),
                            ),
                            const SizedBox(height: NovaSpace.md),
                            TextField(
                              controller: _tunnelPort,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: s.relayTunnelPortLabel,
                                hintText: '1080',
                              ),
                            ),
                            _HelperText(s.relayTunnelPortHelp),
                            const SizedBox(height: NovaSpace.md),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: NovaButton(
                                    label: _tunnelBusy
                                        ? s.relayTunnelStarting
                                        : (running
                                            ? s.relayTunnelStop
                                            : s.relayTunnelStart),
                                    icon: running
                                        ? Icons.stop_rounded
                                        : Icons.play_arrow_rounded,
                                    variant: running
                                        ? NovaButtonVariant.danger
                                        : NovaButtonVariant.primary,
                                    loading: _tunnelBusy,
                                    onPressed:
                                        _tunnelBusy ? null : _toggleTunnel,
                                  ),
                                ),
                                const SizedBox(width: NovaSpace.sm),
                                Expanded(
                                  child: NovaButton(
                                    label: s.relayTunnelTest,
                                    icon: Icons.wifi_tethering_rounded,
                                    variant: NovaButtonVariant.secondary,
                                    onPressed:
                                        _tunnelBusy ? null : _testTunnel,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: NovaSpace.sm),
                            _HelperText(s.relayTunnelHint),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: NovaSpace.lg),

                  // ---- Guide link ----
                  NovaCard(
                    onTap: _openGuide,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NovaSpace.lg,
                      vertical: NovaSpace.md,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.menu_book_rounded, color: nova.cyan),
                        const SizedBox(width: NovaSpace.md),
                        Expanded(
                          child: Text(s.relayHowItWorks,
                              style: text.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600)),
                        ),
                        Icon(Icons.chevron_right_rounded, color: nova.muted),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A muted helper line sitting under a text field, matching the field's
/// leading inset so it reads as part of that input.
class _HelperText extends StatelessWidget {
  const _HelperText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: context.nova.muted),
      ),
    );
  }
}

/// A readable, plain-language explainer for the Google relay: what it is, why it
/// helps under a domain block, the honest limit (config only, not the tunnel),
/// and the numbered setup steps. Reached from [RelayScreen].
class RelayGuideScreen extends StatelessWidget {
  const RelayGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;

    return Scaffold(
      appBar: AppBar(title: Text(s.relayGuideTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            children: <Widget>[
              _GuideSection(
                icon: Icons.hub_rounded,
                color: nova.info,
                title: s.relayGuideWhatTitle,
                body: s.relayGuideWhatBody,
              ),
              const SizedBox(height: NovaSpace.md),
              _GuideSection(
                icon: Icons.lock_open_rounded,
                color: nova.cyan,
                title: s.relayGuideWhyTitle,
                body: s.relayGuideWhyBody,
              ),
              const SizedBox(height: NovaSpace.md),
              // The honest limit is called out with a warning tint so it does
              // not get skimmed past. This is the one people misunderstand.
              _GuideSection(
                icon: Icons.warning_amber_rounded,
                color: nova.warning,
                title: s.relayGuideLimitTitle,
                body: s.relayGuideLimitBody,
                emphasized: true,
              ),
              const SizedBox(height: NovaSpace.md),
              _GuideSection(
                icon: Icons.bolt_rounded,
                color: nova.cyan,
                title: s.relayGuideFrontTitle,
                body: s.relayGuideFrontBody,
              ),
              const SizedBox(height: NovaSpace.md),
              _GuideSection(
                icon: Icons.vpn_lock_rounded,
                color: nova.warning,
                title: s.relayGuideTunnelTitle,
                body: s.relayGuideTunnelBody,
              ),
              const SizedBox(height: NovaSpace.md),
              _StepsCard(
                title: s.relayGuideStepsTitle,
                steps: <String>[
                  s.relayGuideStep1,
                  s.relayGuideStep2,
                  s.relayGuideStep3,
                  s.relayGuideStep4,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One explainer block: a tinted icon chip + heading, then body copy. When
/// [emphasized] it gets a colored border so it stands apart from the rest.
class _GuideSection extends StatelessWidget {
  const _GuideSection({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.emphasized = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      borderColor: emphasized ? color.withValues(alpha: 0.45) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NovaIconChip(icon: icon, color: color, size: 32, radius: 9),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Text(title,
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.md),
          Text(
            body,
            style: text.bodyMedium?.copyWith(color: nova.muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// The numbered setup steps, each with an accent number badge.
class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.title, required this.steps});

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NovaIconChip(
                  icon: Icons.list_alt_rounded,
                  color: nova.violet,
                  size: 32,
                  radius: 9),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Text(title,
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.lg),
          for (int i = 0; i < steps.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: NovaSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _StepNumber(i + 1),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      steps[i],
                      style: text.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A small circular accent badge holding a step number.
class _StepNumber extends StatelessWidget {
  const _StepNumber(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: nova.cyan.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Text(
        '$n',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: nova.cyan,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}
