import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import '../panel/open_panel.dart';
import 'settings_controller.dart';

/// Settings > Server owner: everything about the panel behind a subscription.
///
/// It is one screen and not three rows in General because it is one audience.
/// Most people using Nova were handed a subscription link and will never own a
/// panel; the person who does owns all three of these at once. Grouping them
/// keeps the main Settings list about the app rather than about running a
/// server.
class ServerOwnerScreen extends StatefulWidget {
  const ServerOwnerScreen({super.key});

  @override
  State<ServerOwnerScreen> createState() => _ServerOwnerScreenState();
}

class _ServerOwnerScreenState extends State<ServerOwnerScreen> {
  TextEditingController? _url;

  @override
  void dispose() {
    _url?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final SettingsController settings = NovaScope.of(context).settings;
    _url ??= TextEditingController(text: settings.panelUrl);

    return Scaffold(
      appBar: AppBar(title: Text(s.setServerOwner)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (BuildContext context, _) {
          final Uri? uri = settings.panelUri;
          return Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
              child: ListView(
                padding: NovaSpace.page(context),
                children: <Widget>[
                  Text(s.setServerOwnerSub,
                      style: text.bodySmall?.copyWith(color: nova.muted)),
                  const SizedBox(height: NovaSpace.lg),
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // The address is always LTR, whatever the UI language.
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: TextField(
                            controller: _url,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            onChanged: settings.setPanelUrl,
                            decoration: InputDecoration(
                              labelText: s.panelUrlLabel,
                              hintText: s.panelUrlHint,
                              prefixIcon: const Icon(Icons.dashboard_rounded),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(height: NovaSpace.sm),
                        Text(s.panelUrlHelp,
                            style:
                                text.bodySmall?.copyWith(color: nova.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.lg),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        SwitchListTile(
                          value: settings.panelShortcut,
                          onChanged:
                              uri == null ? null : settings.setPanelShortcut,
                          secondary: Icon(Icons.space_dashboard_rounded,
                              color: nova.cyan),
                          title:
                              Text(s.panelShortcut, style: text.bodyMedium),
                          subtitle: Text(s.panelShortcutSub,
                              style:
                                  text.bodySmall?.copyWith(color: nova.muted)),
                        ),
                        Divider(height: 1, color: nova.border),
                        ListTile(
                          leading: Icon(Icons.open_in_new_rounded,
                              color: nova.cyan),
                          title: Text(s.panelOpen, style: text.bodyMedium),
                          subtitle: Text(
                              uri == null ? s.panelNotSet : s.panelOpenSub,
                              style:
                                  text.bodySmall?.copyWith(color: nova.muted)),
                          trailing:
                              const Icon(Icons.chevron_right_rounded, size: 20),
                          onTap: uri == null
                              ? null
                              : () => openPanel(context, uri),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
