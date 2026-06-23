import 'package:flutter/material.dart';

/// Minimal, dependency-free localization for Nova Client.
///
/// Nova is bilingual (English + فارسی). Rather than pull in the full intl
/// codegen toolchain, strings live in two maps keyed by a stable string id.
/// Persian automatically renders right-to-left because the locale is wired
/// through [MaterialApp.supportedLocales] / `localeResolutionCallback`.
class NovaStrings {
  NovaStrings(this.locale);

  final Locale locale;

  bool get isFarsi => locale.languageCode == 'fa';

  static const LocalizationsDelegate<NovaStrings> delegate =
      _NovaStringsDelegate();

  static NovaStrings of(BuildContext context) {
    return Localizations.of<NovaStrings>(context, NovaStrings) ??
        NovaStrings(const Locale('en'));
  }

  String t(String id) {
    final table = isFarsi ? _fa : _en;
    return table[id] ?? _en[id] ?? id;
  }

  // ---- Navigation ----
  String get navDashboard => t('nav.dashboard');
  String get navProfiles => t('nav.profiles');
  String get navRadar => t('nav.radar');
  String get navRouting => t('nav.routing');
  String get navSettings => t('nav.settings');

  // ---- Dashboard / connection ----
  String get connect => t('dash.connect');
  String get disconnect => t('dash.disconnect');
  String get connecting => t('dash.connecting');
  String get connected => t('dash.connected');
  String get disconnected => t('dash.disconnected');
  String get tapToConnect => t('dash.tapToConnect');
  String get download => t('dash.download');
  String get upload => t('dash.upload');
  String get activeProfile => t('dash.activeProfile');
  String get noProfile => t('dash.noProfile');

  // ---- Radar ----
  String get radarTitle => t('radar.title');
  String get radarSubtitle => t('radar.subtitle');
  String get startScan => t('radar.start');
  String get stopScan => t('radar.stop');
  String get scanning => t('radar.scanning');
  String get deepTesting => t('radar.deepTesting');
  String get alive => t('radar.alive');
  String get dead => t('radar.dead');
  String get scanned => t('radar.scanned');
  String get eta => t('radar.eta');
  String get results => t('radar.results');
  String get noResults => t('radar.noResults');
  String get sources => t('radar.sources');
  String get ports => t('radar.ports');
  String get copyAll => t('radar.copyAll');
  String get latency => t('radar.latency');

  // ---- Common ----
  String get save => t('common.save');
  String get cancel => t('common.cancel');
  String get reset => t('common.reset');
  String get add => t('common.add');
  String get theme => t('common.theme');
  String get language => t('common.language');
  String get about => t('common.about');

  static const Map<String, String> _en = <String, String>{
    'nav.dashboard': 'Home',
    'nav.profiles': 'Profiles',
    'nav.radar': 'Radar',
    'nav.routing': 'Routing',
    'nav.settings': 'Settings',
    'dash.connect': 'Connect',
    'dash.disconnect': 'Disconnect',
    'dash.connecting': 'Connecting…',
    'dash.connected': 'Connected',
    'dash.disconnected': 'Not connected',
    'dash.tapToConnect': 'Tap to connect',
    'dash.download': 'Download',
    'dash.upload': 'Upload',
    'dash.activeProfile': 'Active profile',
    'dash.noProfile': 'No profile selected',
    'radar.title': 'Nova Radar',
    'radar.subtitle': 'Find the fastest Cloudflare clean IPs',
    'radar.start': 'Start scan',
    'radar.stop': 'Stop',
    'radar.scanning': 'Scanning',
    'radar.deepTesting': 'Verifying (TLS handshake)…',
    'radar.alive': 'Alive',
    'radar.dead': 'Dead',
    'radar.scanned': 'Scanned',
    'radar.eta': 'ETA',
    'radar.results': 'Results',
    'radar.noResults': 'No clean IPs yet — start a scan.',
    'radar.sources': 'IP sources',
    'radar.ports': 'Ports',
    'radar.copyAll': 'Copy all',
    'radar.latency': 'Latency',
    'common.save': 'Save',
    'common.cancel': 'Cancel',
    'common.reset': 'Reset',
    'common.add': 'Add',
    'common.theme': 'Theme',
    'common.language': 'Language',
    'common.about': 'About',
  };

  static const Map<String, String> _fa = <String, String>{
    'nav.dashboard': 'خانه',
    'nav.profiles': 'پروفایل‌ها',
    'nav.radar': 'رادار',
    'nav.routing': 'مسیریابی',
    'nav.settings': 'تنظیمات',
    'dash.connect': 'اتصال',
    'dash.disconnect': 'قطع اتصال',
    'dash.connecting': 'در حال اتصال…',
    'dash.connected': 'متصل شد',
    'dash.disconnected': 'متصل نیست',
    'dash.tapToConnect': 'برای اتصال لمس کنید',
    'dash.download': 'دانلود',
    'dash.upload': 'آپلود',
    'dash.activeProfile': 'پروفایل فعال',
    'dash.noProfile': 'پروفایلی انتخاب نشده',
    'radar.title': 'رادار نوا',
    'radar.subtitle': 'سریع‌ترین آی‌پی‌های تمیز کلودفلر را پیدا کنید',
    'radar.start': 'شروع اسکن',
    'radar.stop': 'توقف',
    'radar.scanning': 'در حال اسکن',
    'radar.deepTesting': 'در حال تأیید (دست‌دهی TLS)…',
    'radar.alive': 'فعال',
    'radar.dead': 'غیرفعال',
    'radar.scanned': 'بررسی‌شده',
    'radar.eta': 'زمان باقی‌مانده',
    'radar.results': 'نتایج',
    'radar.noResults': 'هنوز آی‌پی تمیزی نیست — اسکن را شروع کنید.',
    'radar.sources': 'منابع آی‌پی',
    'radar.ports': 'پورت‌ها',
    'radar.copyAll': 'کپی همه',
    'radar.latency': 'تأخیر',
    'common.save': 'ذخیره',
    'common.cancel': 'لغو',
    'common.reset': 'بازنشانی',
    'common.add': 'افزودن',
    'common.theme': 'پوسته',
    'common.language': 'زبان',
    'common.about': 'درباره',
  };
}

class _NovaStringsDelegate extends LocalizationsDelegate<NovaStrings> {
  const _NovaStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'fa';

  @override
  Future<NovaStrings> load(Locale locale) async => NovaStrings(locale);

  @override
  bool shouldReload(_NovaStringsDelegate old) => false;
}
