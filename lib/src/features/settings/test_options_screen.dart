import 'package:flutter/material.dart';

import '../../core/proxy/singbox/singbox_config.dart';
import '../../core/proxy/list_freshness.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import 'settings_controller.dart';

/// Settings > Test options: what every latency measurement fetches, how long a
/// server may take before it counts as "no response", how often the live
/// auto-select group re-tests, and how much faster a server must be before the
/// group switches.
///
/// One screen because one set of numbers drives both measurements a user sees:
/// the lightning test in the server list and the auto-selector inside the
/// running tunnel. The timeout in particular is per server and starts when that
/// server's own test starts, so raising it costs time only on servers that are
/// genuinely slow to answer.
class TestOptionsScreen extends StatelessWidget {
  const TestOptionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final SettingsController settings = NovaScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: Text(s.setTestOptions)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (BuildContext context, _) => Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: ListView(
              padding: NovaSpace.page(context),
              children: <Widget>[
                _AutoRefreshCard(settings: settings),
                const SizedBox(height: 16),
                _UrlTestCard(settings: settings),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// When a server list refreshes and re-tests itself on its own.
///
/// Worth being explicit about, because the answer used to be "every time you
/// open it", which cost a few hundred dials for nothing and threw away readings
/// the user had just watched appear.
class _AutoRefreshCard extends StatelessWidget {
  const _AutoRefreshCard({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final ThemeData theme = Theme.of(context);
    final int hours = ListFreshness.maxAge.inHours;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            value: settings.autoRefreshLists,
            onChanged: settings.setAutoRefreshLists,
            title: Text(s.testAutoRefreshTitle),
            subtitle: Text(
              s.testAutoRefreshBody.replaceFirst('{h}', '\u2066$hours\u2069'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              settings.autoRefreshLists
                  ? s.testAutoRefreshOn.replaceFirst('{h}', '\u2066$hours\u2069')
                  : s.testAutoRefreshOff,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The card itself. Text fields commit on change; bad numbers are ignored.
class _UrlTestCard extends StatefulWidget {
  const _UrlTestCard({required this.settings});
  final SettingsController settings;

  @override
  State<_UrlTestCard> createState() => _UrlTestCardState();
}

class _UrlTestCardState extends State<_UrlTestCard> {
  late final TextEditingController _url =
      TextEditingController(text: widget.settings.urlTestUrl);
  late final TextEditingController _timeout =
      TextEditingController(text: '${widget.settings.urlTestTimeoutSec}');
  late final TextEditingController _interval =
      TextEditingController(text: '${widget.settings.urlTestIntervalSec}');
  late final TextEditingController _tolerance =
      TextEditingController(text: '${widget.settings.urlTestToleranceMs}');

  @override
  void dispose() {
    _url.dispose();
    _timeout.dispose();
    _interval.dispose();
    _tolerance.dispose();
    super.dispose();
  }

  Widget _num(BuildContext context, TextEditingController c, String label,
      String unit, String help, void Function(int) onChanged) {
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.only(top: NovaSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: label, suffixText: unit),
            onChanged: (String v) {
              final int? n = int.tryParse(v.trim());
              if (n != null) onChanged(n);
            },
          ),
          const SizedBox(height: 4),
          Text(help,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.urlTestTitle,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(s.urlTestSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: s.urlTestUrl,
              hintText: kDefaultUrlTestUrl,
            ),
            onChanged: widget.settings.setUrlTestUrl,
          ),
          const SizedBox(height: 4),
          Text(s.urlTestUrlHelp,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          _num(context, _timeout, s.urlTestTimeout, 's', s.urlTestTimeoutHelp,
              widget.settings.setUrlTestTimeoutSec),
          _num(context, _interval, s.urlTestInterval, 's',
              s.urlTestIntervalHelp, widget.settings.setUrlTestIntervalSec),
          _num(context, _tolerance, s.urlTestTolerance, 'ms',
              s.urlTestToleranceHelp, widget.settings.setUrlTestToleranceMs),
        ],
      ),
    );
  }
}
