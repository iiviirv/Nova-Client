import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_components.dart';

/// Deploy a new Nova worker. This is now handled by the Telegram bot: the user
/// pastes a Cloudflare API token into the bot and it creates the Worker, D1, KV
/// and workers.dev subdomain on their account and installs Nova. The client just
/// hands the user off to the bot (no in-app Cloudflare OAuth or token handling).
class DeployScreen extends StatelessWidget {
  const DeployScreen({super.key});

  static const String botUrl = 'https://t.me/IRNovaProxy_Bot';

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.serversDeploy)),
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.all(NovaSpace.lg),
            children: <Widget>[
              const SizedBox(height: NovaSpace.md),
              Center(
                child: NovaIconChip(
                  icon: Icons.send_rounded,
                  color: nova.cyan,
                  size: 56,
                  radius: 16,
                ),
              ),
              const SizedBox(height: NovaSpace.lg),
              Text(s.deployBotTitle,
                  textAlign: TextAlign.center,
                  style:
                      text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: NovaSpace.sm),
              Text(s.deployBotIntro,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: nova.muted)),
              const SizedBox(height: NovaSpace.xl),
              NovaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _step(context, '1', s.deployBotStep1),
                    _step(context, '2', s.deployBotStep2),
                    _step(context, '3', s.deployBotStep3, last: true),
                  ],
                ),
              ),
              const SizedBox(height: NovaSpace.xl),
              NovaButton(
                label: s.deployBotOpen,
                icon: Icons.open_in_new_rounded,
                onPressed: () => launchUrl(Uri.parse(botUrl),
                    mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(BuildContext context, String n, String label,
      {bool last = false}) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : NovaSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: nova.cyan.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(n,
                style: text.labelMedium
                    ?.copyWith(color: nova.cyan, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(label, style: text.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}
