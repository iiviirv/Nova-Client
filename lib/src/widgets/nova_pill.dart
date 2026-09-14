import 'package:flutter/material.dart';

import '../theme/nova_radii.dart';
import '../theme/nova_theme.dart';

/// A translucent accent pill / chip. Optionally selectable (used for the Radar
/// port selector and source toggles).
class NovaPill extends StatelessWidget {
  const NovaPill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color accent = color ?? nova.cyan;
    final Color fill =
        selected ? accent.withValues(alpha: 0.16) : nova.surface;
    final Color border =
        selected ? accent.withValues(alpha: 0.55) : nova.border;
    final Color fg = selected ? accent : nova.muted;

    final Widget pill = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NovaSpace.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: NovaRadii.pillR,
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          // Flexible, so a long label on a narrow screen at a large text scale
          // shrinks the pill instead of overflowing it. Found on the Aether
          // editor at 320dp and 2x text, where "aggressive" wanted 35px more
          // than the card it sits in has. Unconstrained callers are unaffected:
          // a Flexible child under loose constraints still takes its own size.
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return pill;
    return InkWell(
      borderRadius: NovaRadii.pillR,
      onTap: onTap,
      child: pill,
    );
  }
}
