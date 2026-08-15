import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import 'servers_body.dart';

/// The Servers tab: a plain title with the shared [ServersBody], and a small
/// round Add button floating over the list (bottom-end) instead of a header
/// action, so it stays reachable one-handed and out of the list's way.
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
              child: Text(s.navServers,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  const ServersBody(),
                  PositionedDirectional(
                    end: NovaSpace.lg,
                    bottom: NovaSpace.lg,
                    child: _AddFab(onPressed: () => showAddConfigSheet(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round, floating Add button in the signature gradient. Small on purpose: it
/// hovers over the list without crowding it, and the tooltip/semantics keep it
/// as clear as the old labelled action.
class _AddFab extends StatelessWidget {
  const _AddFab({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    return Semantics(
      button: true,
      label: s.add,
      child: Tooltip(
        message: s.add,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: NovaGradients.signature,
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: nova.indigo.withValues(alpha: 0.45),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(Icons.add_rounded, color: nova.onAccent, size: 28),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
