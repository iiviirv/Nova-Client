import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_theme.dart';

/// Who built the parts of Nova that Nova did not build.
///
/// This exists for two reasons and the first one is not optional. The WARP core
/// is AGPL-3.0 and the Psiphon engine is GPL-3.0; shipping either without its
/// notice and a pointer to its source is a licence breach, and until this
/// screen existed the app shipped both with neither. The second reason is that
/// people outside this project did work the app depends on, and a line in a
/// changelog nobody reads is not credit.
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.creditsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _Blurb(s.creditsIntro),
          const SizedBox(height: 20),
          _Credit(
            name: 'Aether',
            by: 'CluvexStudio',
            licence: 'AGPL-3.0',
            what: s.creditsAether,
            url: 'https://github.com/CluvexStudio/Aether',
          ),
          _Credit(
            name: 'PattNG',
            by: 'patterniha',
            licence: '',
            what: s.creditsPattng,
            url: 'https://github.com/patterniha/PattNG',
          ),
          _Credit(
            name: 'Psiphon',
            by: 'Psiphon Inc.',
            licence: 'GPL-3.0',
            what: s.creditsPsiphon,
            url: 'https://github.com/Psiphon-Labs/psiphon-tunnel-core',
          ),
          _Credit(
            name: 'sing-box',
            by: 'SagerNet',
            licence: 'GPL-3.0',
            what: s.creditsSingbox,
            url: 'https://github.com/SagerNet/sing-box',
          ),
          _Credit(
            name: 'Xray-core',
            by: 'XTLS',
            licence: 'MPL-2.0',
            what: s.creditsXray,
            url: 'https://github.com/XTLS/Xray-core',
          ),
          const SizedBox(height: 12),
          _Blurb(s.creditsSource),
        ],
      ),
    );
  }
}

class _Blurb extends StatelessWidget {
  const _Blurb(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: context.nova.muted),
      );
}

class _Credit extends StatelessWidget {
  const _Credit({
    required this.name,
    required this.by,
    required this.licence,
    required this.what,
    required this.url,
  });

  final String name;
  final String by;
  final String licence;
  final String what;
  final String url;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Flexible(
                  child: Text(name,
                      style: text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                if (licence.isNotEmpty)
                  Text(licence,
                      style: text.labelSmall?.copyWith(color: nova.muted)),
              ],
            ),
            Text(by, style: text.bodySmall?.copyWith(color: nova.muted)),
            const SizedBox(height: 4),
            Text(what, style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}
