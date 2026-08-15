import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../widgets/nova_button.dart';
import 'servers_body.dart';

/// The Servers tab: a header with an Add action over the shared [ServersBody].
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NovaSpace.lg, NovaSpace.lg, NovaSpace.lg, NovaSpace.sm),
              child: Row(
                children: <Widget>[
                  // The title yields to the action: at a large text scale on
                  // a narrow phone the button must stay whole and reachable.
                  Expanded(
                    child: Text(s.navServers,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: NovaSpace.md),
                  NovaButton(
                    label: s.add,
                    icon: Icons.add_rounded,
                    onPressed: () => showAddConfigSheet(context),
                  ),
                ],
              ),
            ),
            const Expanded(child: ServersBody()),
          ],
        ),
      ),
    );
  }
}
