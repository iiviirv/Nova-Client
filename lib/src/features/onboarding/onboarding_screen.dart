import 'package:flutter/material.dart';

import '../../theme/nova_colors.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_logo.dart';

/// First-run onboarding, matching Nova v1.0.0: pick a language, then choose how
/// to start (deploy your own panel, import from a panel, connect a VPS, or add
/// a config). Text switches live with the language (and flips to RTL for
/// Persian).
///
/// Copy is inline here on purpose: the language step has to show both
/// languages before the app locale exists, and [NovaStrings] follows the app
/// locale.
class NovaOnboarding extends StatefulWidget {
  const NovaOnboarding(
      {super.key, required this.onPickLanguage, required this.onFinish});

  /// Apply the chosen locale immediately so the rest of the app follows.
  final void Function(String langCode) onPickLanguage;

  /// action: 'deploy' | 'panel' | 'vps' | 'add' | null (skip).
  final void Function(String? action) onFinish;

  @override
  State<NovaOnboarding> createState() => _NovaOnboardingState();
}

class _NovaOnboardingState extends State<NovaOnboarding> {
  String _lang = 'en';
  int _step = 0;

  bool get _fa => _lang == 'fa';

  String _t(String en, String fa) => _fa ? fa : en;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Directionality(
      textDirection: _fa ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                    NovaSpace.xl, NovaSpace.xxl, NovaSpace.xl, NovaSpace.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Center(child: NovaLogo(size: 88)),
                    const SizedBox(height: NovaSpace.xl),
                    Text(_t('Welcome to Nova', 'به نوا خوش آمدید'),
                        style: text.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                        textAlign: TextAlign.center),
                    const SizedBox(height: NovaSpace.sm),
                    Text(
                        _t('Fast, free, unrestricted internet.',
                            'اینترنت سریع، رایگان و بدون محدودیت.'),
                        style: text.bodyMedium?.copyWith(color: nova.muted),
                        textAlign: TextAlign.center),
                    const SizedBox(height: NovaSpace.lg),
                    _StepDots(step: _step, count: 2),
                    const SizedBox(height: NovaSpace.xl),
                    // A one-shot fade between the two steps; nothing animates
                    // while a step is on screen.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (Widget child, Animation<double> a) =>
                          FadeTransition(opacity: a, child: child),
                      layoutBuilder: (Widget? current, List<Widget> previous) =>
                          Stack(
                        alignment: Alignment.topCenter,
                        children: <Widget>[...previous, if (current != null) current],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey<int>(_step),
                        child: _step == 0
                            ? _languageStep(context, nova)
                            : _startStep(context, nova),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _languageStep(BuildContext context, NovaColors nova) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_t('Choose your language', 'زبان خود را انتخاب کنید'),
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: NovaSpace.md),
        _langTile('en', 'English', 'Aa', nova),
        const SizedBox(height: NovaSpace.sm + 2),
        _langTile('fa', 'فارسی', 'فا', nova),
        const SizedBox(height: NovaSpace.xl),
        NovaButton(
          label: _t('Get started', 'شروع کنیم'),
          expand: true,
          onPressed: () => setState(() => _step = 1),
        ),
      ],
    );
  }

  Widget _langTile(String code, String label, String glyph, NovaColors nova) {
    final bool sel = _lang == code;
    final text = Theme.of(context).textTheme;
    return _SelectCard(
      selected: sel,
      onTap: () {
        setState(() => _lang = code);
        widget.onPickLanguage(code);
      },
      child: Row(
        children: <Widget>[
          _GlyphTile(
            selected: sel,
            child: Text(glyph,
                style: text.titleSmall?.copyWith(
                  color: sel ? nova.onAccent : nova.text,
                  fontWeight: FontWeight.w800,
                )),
          ),
          const SizedBox(width: NovaSpace.md + 2),
          Expanded(
            child: Text(label,
                style: text.titleMedium?.copyWith(
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ),
          Icon(
            sel ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: sel ? nova.cyan : nova.borderStrong,
            size: 22,
          ),
        ],
      ),
    );
  }

  Widget _startStep(BuildContext context, NovaColors nova) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_t('How would you like to start?', 'چطور می‌خواهید شروع کنید؟'),
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
        const SizedBox(height: NovaSpace.sm),
        Text(
            _t('Pick one to get connected. You can change this anytime.',
                'یکی را انتخاب کنید تا وصل شوید. هر زمان می‌توانید تغییرش دهید.'),
            style: text.bodySmall?.copyWith(color: nova.muted),
            textAlign: TextAlign.center),
        const SizedBox(height: NovaSpace.xl),
        // First and highlighted, because it is the only option that needs
        // nothing from the person reading it: the free servers are already in
        // the list, so this closes onboarding straight onto a Connect button
        // that works. Everything below it asks for an account, a server or a
        // link first.
        _choice(context, Icons.card_giftcard_rounded,
            _t('Use the free servers', 'استفاده از سرورهای رایگان'),
            _t('Already set up. Just press Connect.',
                'همین حالا آماده است. فقط اتصال را بزنید.'),
            highlighted: true, onTap: () => widget.onFinish('free')),
        // Deploying a panel, signing in to one, and connecting a VPS used to
        // sit here too. All three asked a brand new user for something they do
        // not have yet (a Cloudflare account, a panel login, a server), and two
        // of them opened the very same screen. They are panel-owner tools and
        // they live where an owner looks for them: Settings > Cloudflare tools,
        // and the Servers page's own empty state.
        const SizedBox(height: NovaSpace.sm + 2),
        _choice(context, Icons.add_rounded,
            _t('Add a config', 'افزودن کانفیگ'),
            _t('Paste a link or a subscription URL', 'چسباندن لینک یا آدرس اشتراک'),
            onTap: () => widget.onFinish('add')),
        const SizedBox(height: NovaSpace.md),
        Center(
          child: TextButton(
            onPressed: () => widget.onFinish(null),
            style: TextButton.styleFrom(
              foregroundColor: nova.muted,
              minimumSize: const Size(44, 44),
            ),
            child: Text(_t("I'll do this later", 'بعداً انجام می‌دهم')),
          ),
        ),
      ],
    );
  }

  Widget _choice(
      BuildContext context, IconData icon, String title, String subtitle,
      {bool highlighted = false, required VoidCallback onTap}) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return _SelectCard(
      selected: highlighted,
      onTap: onTap,
      child: Row(
        children: <Widget>[
          _GlyphTile(
            selected: true,
            child: Icon(icon, color: nova.onAccent, size: 22),
          ),
          const SizedBox(width: NovaSpace.md + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: text.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: text.bodySmall?.copyWith(color: nova.muted)),
              ],
            ),
          ),
          const SizedBox(width: NovaSpace.sm),
          Icon(_fa ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
              color: nova.muted),
        ],
      ),
    );
  }
}

/// A tappable card that can be the current pick: a cyan hairline and a faint
/// tint when selected, the plain surface otherwise (the same treatment as the
/// active server row, so the language reads the same on day one and day ten).
class _SelectCard extends StatelessWidget {
  const _SelectCard({
    required this.child,
    required this.onTap,
    required this.selected,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Material(
      color: selected ? nova.cyan.withValues(alpha: 0.07) : nova.surface,
      shape: RoundedRectangleBorder(
        borderRadius: NovaRadii.cardR,
        side: BorderSide(
            color: selected ? nova.cyan.withValues(alpha: 0.5) : nova.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          selected: selected,
          child: Padding(
            padding: const EdgeInsets.all(NovaSpace.lg),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A 40dp tile holding a glyph or icon: the brand gradient when [selected],
/// the raised surface otherwise.
class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.child, required this.selected});
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: selected ? NovaGradients.logo : null,
        color: selected ? null : nova.surface2,
        borderRadius: NovaRadii.chipR,
      ),
      child: child,
    );
  }
}

/// Two dots under the header: which of the two steps this is. Decorative for
/// assistive tech; the step's own heading carries the meaning.
class _StepDots extends StatelessWidget {
  const _StepDots({required this.step, required this.count});
  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < count; i++) ...<Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: i == step ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == step ? nova.cyan : nova.borderStrong,
                borderRadius: NovaRadii.pillR,
              ),
            ),
            if (i < count - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}
