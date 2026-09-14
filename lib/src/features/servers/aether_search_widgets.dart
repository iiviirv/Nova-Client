import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import 'aether_gateway_search.dart';

/// The wait, promised before it starts.
///
/// A gateway search took about three minutes on the tester's network. Three
/// minutes of a silent button reads as a feature that is broken, so the two
/// places that can start one both say so up front, in the same words, out of
/// the same widget.
class AetherWaitHint extends StatelessWidget {
  const AetherWaitHint({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(NovaSpace.sm),
      decoration: BoxDecoration(
        color: nova.warning.withValues(alpha: 0.10),
        borderRadius: NovaRadii.smR,
        border: Border.all(color: nova.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            // The tint carries the warning and the icon carries the colour.
            // Amber on the light surface is about 2:1 against body text, so the
            // words themselves stay on a readable colour.
            child: Icon(Icons.schedule_rounded, size: 16, color: nova.warning),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(
              NovaStrings.of(context).aetherSlowHint,
              style: text.bodySmall?.copyWith(color: nova.muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where a running search has got to: a bar, which address it is on, and how
/// many have already been ruled out.
class AetherProgressLines extends StatelessWidget {
  const AetherProgressLines({super.key, required this.progress});

  final AetherSearchProgress progress;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: NovaRadii.pillR,
          child: LinearProgressIndicator(
            minHeight: 3,
            backgroundColor: nova.border,
            valueColor: AlwaysStoppedAnimation<Color>(nova.cyan),
          ),
        ),
        const SizedBox(height: NovaSpace.sm),
        Text(
          progress.verifying
              ? s.aetherVerifyingAt(progress.attempt)
              : s.aetherScanningAt(progress.attempt),
          style: text.bodySmall?.copyWith(color: nova.text),
        ),
        if (progress.ruledOut > 0)
          Text(s.aetherRuledOut(progress.ruledOut),
              style: text.bodySmall?.copyWith(color: nova.muted)),
      ],
    );
  }
}
