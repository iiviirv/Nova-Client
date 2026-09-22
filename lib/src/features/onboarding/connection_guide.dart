import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';

/// The same connection advice on first launch and in Settings.
class ConnectionGuideScreen extends StatelessWidget {
  const ConnectionGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bool fa = NovaStrings.of(context).isFarsi;
    return Scaffold(
      appBar: AppBar(title: Text(fa ? 'راهنمای اتصال' : 'Connection guide')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(NovaSpace.lg),
              child: ConnectionGuideContent(isFarsi: fa),
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionGuideContent extends StatelessWidget {
  const ConnectionGuideContent(
      {super.key, required this.isFarsi, this.onboarding = false});
  final bool onboarding;
  final bool isFarsi;
  String _t(String en, String fa) => isFarsi ? fa : en;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_t('Choose your connection', 'روش اتصال را انتخاب کنید'),
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: NovaSpace.sm),
        Text(
          _t('Start with Free VPN. If it cannot connect on your network, try another route below.',
              'با VPN رایگان شروع کنید. اگر در شبکه شما وصل نشد، روش دیگری را امتحان کنید.'),
          style: text.bodyMedium?.copyWith(color: nova.muted),
        ),
        const SizedBox(height: NovaSpace.lg),
        _route(
          context,
          icon: Icons.public_rounded,
          color: nova.cyan,
          title: _t('Free VPN servers', 'سرورهای VPN رایگان'),
          badge: _t('Start here', 'از اینجا شروع کنید'),
          description: _t(
              'A ready-made list of shared servers. No config or server of your own is needed. Availability and speed can change.',
              'فهرستی آماده از سرورهای اشتراکی. به کانفیگ یا سرور شخصی نیاز ندارید. دسترسی و سرعت ممکن است تغییر کند.'),
          steps: _t(
              'Select Nova free servers, then tap Connect.\nIn Servers, refresh the list or test servers if the connection is slow.',
              'سرورهای رایگان نوا را انتخاب کنید و اتصال را بزنید.\nاگر اتصال کند است، در بخش سرورها فهرست را تازه‌سازی یا سرورها را آزمایش کنید.'),
        ),
        const SizedBox(height: NovaSpace.md),
        _route(
          context,
          icon: Icons.shield_moon_rounded,
          color: nova.violet,
          title: 'Aether',
          badge: _t('WARP tunnel', 'تونل WARP'),
          description: _t(
              'Connect through Cloudflare WARP. Nova searches for a reachable gateway and checks that it carries traffic before saving it.',
              'اتصال از طریق WARP کلادفلر. نوا یک درگاه در دسترس پیدا می‌کند و پیش از ذخیره، عبور ترافیک را بررسی می‌کند.'),
          steps: _t(
              'In Servers > Free, choose WireGuard, Gool or MASQUE, then tap Connect.\nKeep the search screen open. Finding a gateway can take a few minutes. If a saved gateway stops working, search again.',
              'در سرورها > رایگان، WireGuard، Gool یا MASQUE را انتخاب کنید و اتصال را بزنید.\nصفحه جستجو را باز نگه دارید؛ یافتن درگاه ممکن است چند دقیقه طول بکشد. اگر درگاه ذخیره‌شده کار نکرد، دوباره جستجو کنید.'),
        ),
        if (!onboarding) ...<Widget>[
          const SizedBox(height: NovaSpace.md),
          _route(
            context,
            icon: Icons.dns_rounded,
            color: nova.indigo,
            title: 'MasterDNS',
            badge: _t('Bring a config', 'با کانفیگ شخصی'),
            description: _t(
                'A tunnel that carries traffic through DNS. It needs a working MasterDNS server and matching settings from its operator. It can be slower than other connection types.',
                'تونلی که ترافیک را از طریق DNS منتقل می‌کند. به سرور فعال MasterDNS و تنظیمات هماهنگ از مدیر آن نیاز دارد. ممکن است از روش‌های دیگر کندتر باشد.'),
            steps: _t(
                'In Servers, add MasterDNS or paste its config.\nCheck the domain, encryption key, method and resolvers with your provider, then save and connect. If it fails, check those values and try reachable resolvers.',
                'در سرورها MasterDNS را اضافه کنید یا کانفیگ آن را بچسبانید.\nدامنه، کلید رمزگذاری، روش و DNSها را با ارائه‌دهنده بررسی کنید، سپس ذخیره و متصل شوید. اگر وصل نشد، تنظیمات و دسترسی DNSها را بررسی کنید.'),
          ),
        ],
        const SizedBox(height: NovaSpace.lg),
        Text(_t('Make the connection yours', 'اتصال مناسب خودتان'),
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: NovaSpace.sm),
        Text(
            _t('You can also import a config or subscription from your provider in Servers. Settings includes routing, connection tests and logs; server-owner tools help you manage your own service.',
                'در سرورها می‌توانید کانفیگ یا اشتراک ارائه‌دهنده خود را نیز وارد کنید. تنظیمات شامل مسیریابی، آزمایش اتصال و گزارش‌هاست؛ ابزارهای صاحبان سرور برای مدیریت سرویس شخصی هستند.'),
            style: text.bodyMedium),
        const SizedBox(height: NovaSpace.sm),
        Text(
            _t('Allow the system VPN request when connecting on a phone. On desktop, check whether you want proxy mode or whole-device mode. A connected status alone does not guarantee working internet: check that traffic flows. No method works on every network.',
                'هنگام اتصال در گوشی، درخواست VPN سیستم را تأیید کنید. در دسکتاپ، حالت پراکسی یا کل دستگاه را بررسی کنید. وضعیت متصل به‌تنهایی تضمین اینترنت نیست؛ عبور ترافیک را بررسی کنید. هیچ روشی روی همه شبکه‌ها کار نمی‌کند.'),
            style: text.bodyMedium?.copyWith(color: nova.muted)),
        const SizedBox(height: NovaSpace.md),
        Text(
            _t('Find this guide anytime in Settings > Connection guide.',
                'این راهنما همیشه در تنظیمات > راهنمای اتصال در دسترس است.'),
            style: text.bodySmall?.copyWith(color: nova.cyan)),
      ],
    );
  }

  Widget _route(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String badge,
    required String description,
    required String steps,
  }) {
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[
            Icon(icon, color: color, size: 28),
            const SizedBox(width: NovaSpace.md),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(badge, style: text.labelMedium?.copyWith(color: color)),
                Text(title,
                    style:
                        text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            )),
          ]),
          const SizedBox(height: NovaSpace.md),
          Text(description, style: text.bodyMedium),
          const SizedBox(height: NovaSpace.md),
          Text(steps,
              style: text.bodyMedium
                  ?.copyWith(color: context.nova.muted, height: 1.6)),
        ],
      ),
    );
  }
}
