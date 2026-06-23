import 'package:flutter/material.dart';

import '../theme/nova_radii.dart';
import '../theme/nova_theme.dart';

/// A surface card — translucent fill + hairline border + 16px radius, the
/// workhorse container of the Nova design language.
class NovaCard extends StatelessWidget {
  const NovaCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(NovaSpace.lg),
    this.onTap,
    this.raised = false,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Uses the brighter `surface-2` fill for hover/active emphasis.
  final bool raised;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final BoxDecoration decoration = BoxDecoration(
      color: raised ? nova.surface2 : nova.surface,
      borderRadius: NovaRadii.cardR,
      border: Border.all(color: borderColor ?? nova.border),
    );

    final Widget body = Padding(padding: padding, child: child);

    if (onTap == null) {
      return DecoratedBox(decoration: decoration, child: body);
    }
    return Material(
      color: Colors.transparent,
      borderRadius: NovaRadii.cardR,
      child: InkWell(
        borderRadius: NovaRadii.cardR,
        onTap: onTap,
        child: Ink(decoration: decoration, child: body),
      ),
    );
  }
}

/// A small uppercased "eyebrow" label in the accent color — used above section
/// headings, matching the site's `--tracking-eyebrow` treatment.
class NovaEyebrow extends StatelessWidget {
  const NovaEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    // Eyebrows are a Latin treatment; never uppercase/letter-space Farsi.
    final bool isFarsi = Directionality.of(context) == TextDirection.rtl;
    return Text(
      isFarsi ? text : text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: nova.cyan,
            letterSpacing: isFarsi ? 0 : 1.6,
            fontWeight: FontWeight.w600,
          ),
    );
  }
}
