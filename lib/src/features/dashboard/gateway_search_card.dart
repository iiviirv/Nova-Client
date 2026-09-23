import 'package:flutter/material.dart';

import '../../core/proxy/aether/aether_options.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import '../servers/aether_search_widgets.dart';

/// Visible only while a first or replacement gateway is being discovered.
///
/// Field report, 2026-09-22: this card showed "Scanning at attempt 3" over a
/// bar that never fills, and a tester on an iPhone read that as a hang and
/// stopped a healthy MASQUE search at 70 seconds. The log shows the search was
/// fine, and the automatic HTTP/2 fallback engages at 90 seconds, so the cancel
/// landed 20 seconds before the thing built to rescue exactly that search.
///
/// So the card now carries the readout the editor already had (the phase, a
/// clock that counts up, how many addresses have been ruled out), names the
/// protocol when the search told it which one, and states the fallback as a
/// step of its own. Nothing here claims to know how far along the search is,
/// because nothing does: the finder stops when an address carries traffic, not
/// at a fraction.
class GatewaySearchCard extends StatelessWidget {
  const GatewaySearchCard({super.key});

  /// Key on the expectation line, so a test can hold it without pinning the
  /// wording it is allowed to change.
  static const Key waitKey = Key('gatewaySearchWait');

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
                      ? _t(s, 'Finding a replacement gateway',
                          'در حال یافتن درگاه جایگزین')
                      : _t(s, 'Finding your first gateway',
                          'در حال یافتن اولین درگاه'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NovaSpace.md),
                // Owns the clock, the phase and the fallback note, and is the
                // same widget the editor and the quick setup card use, so a
                // running search reads the same everywhere in the app.
                AetherProgressLines(progress: progress),
                const SizedBox(height: NovaSpace.md),
                // Quieter than the readout above it: it is read once, early,
                // and the live line is what the next two minutes are spent
                // looking at.
                Text(
                  _wait(s, progress.mode),
                  key: waitKey,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.nova.muted, height: 1.35),
                ),
                const SizedBox(height: NovaSpace.md),
                // Full width and 48dp tall rather than the old text link in the
                // corner. Stopping is a fair thing to want, and a search this
                // long should not make someone hunt for the way out; it is the
                // secondary variant because it is not what we expect them to
                // want.
                NovaButton(
                  label: s.aetherCancel,
                  icon: Icons.close_rounded,
                  variant: NovaButtonVariant.secondary,
                  expand: true,
                  onPressed: () {
                    proxy.cancelAetherSearch();
                    proxy.disconnect();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// What to expect of the wait, with no duration attached.
  ///
  /// A number here would be a promise: the measured figures are one tester's
  /// network, and quoting "two minutes" turns a search that takes three into a
  /// broken one. What is safe to say is the ordering, which holds whatever the
  /// network does, plus the one instruction that matters while it runs.
  String _wait(NovaStrings s, AetherMode? mode) => switch (mode) {
        AetherMode.masque => _t(
            s,
            'MASQUE takes the longest of the three protocols to find a '
                'gateway, so a long wait is normal. Keep Nova open until it '
                'finishes.',
            '\u2066MASQUE\u2069 از میان سه پروتکل بیشترین زمان را برای پیدا '
                'کردن درگاه می‌برد، پس انتظار طولانی عادی است. تا پایان '
                'کار نوا را باز نگه دارید.'),
        _ => _t(
            s,
            'How long this takes depends on the protocol, so a long wait is '
                'not a sign of a problem. Keep Nova open until it finishes.',
            'مدت این کار به پروتکل بستگی دارد، پس انتظار طولانی نشانه‌ی مشکل '
                'نیست. تا پایان کار نوا را باز نگه دارید.'),
      };
}

/// This card's own copy, the way it already carried its title: short, tied to
/// one widget, and not worth a key in the shared table.
String _t(NovaStrings s, String en, String fa) => s.isFarsi ? fa : en;
