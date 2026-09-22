import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';

/// Visible only while a first or replacement gateway is being discovered.
class GatewaySearchCard extends StatelessWidget {
  const GatewaySearchCard({super.key});

  @override
  Widget build(BuildContext context) {
    final proxy = NovaScope.of(context).proxy;
    final s = NovaStrings.of(context);
    return ValueListenableBuilder(
      valueListenable: proxy.gatewaySearch,
      builder: (context, search, _) {
        if (search == null) return const SizedBox.shrink();
        final progress = search.progress;
        return Padding(
          padding: const EdgeInsets.only(bottom: NovaSpace.md),
          child: NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  search.replacing
                      ? (s.isFarsi
                          ? 'در حال یافتن درگاه جایگزین'
                          : 'Finding a replacement gateway')
                      : (s.isFarsi
                          ? 'در حال یافتن اولین درگاه'
                          : 'Finding your first gateway'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NovaSpace.sm),
                Text(s.isFarsi
                    ? 'پیدا کردن و بررسی درگاه سالم ممکن است چند دقیقه طول بکشد و از اتصال معمولی زمان بیشتری نیاز دارد. لطفاً نوا را باز نگه دارید و تا پایان این مرحله منتظر بمانید.'
                    : 'Finding and checking a working gateway can take a few minutes, longer than a normal connection. Please keep Nova open and wait for this step to finish.'),
                const SizedBox(height: NovaSpace.md),
                const LinearProgressIndicator(),
                const SizedBox(height: NovaSpace.sm),
                Semantics(
                  liveRegion: true,
                  child: Text(progress.verifying
                      ? s.aetherVerifyingAt(progress.attempt)
                      : s.aetherScanningAt(progress.attempt)),
                ),
                if (progress.usingFallback)
                  Text(s.isFarsi
                      ? 'در حال امتحان HTTP/2 با Split TLS'
                      : 'Trying HTTP/2 with Split TLS'),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () {
                      proxy.cancelAetherSearch();
                      proxy.disconnect();
                    },
                    child: Text(s.aetherCancel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
