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

  // ---- Notices ----
  /// Shown when a manually pinned server turns out to be dead and Nova
  /// auto-switches to the fastest working one.
  String get failoverSwitched => t('notice.failoverSwitched');

  // ---- Radar ----
  /// Short label for a clean IP's latency variance in the results list.
  String get radarJitter => t('radar.jitter');

  /// Short label for a clean IP's packet loss in the results list.
  String get radarLoss => t('radar.loss');

  // ---- Navigation ----
  String get navDashboard => t('nav.dashboard');
  String get navProfiles => t('nav.profiles');
  String get navServers => t('nav.servers');
  String get navStats => t('nav.stats');
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
  String get subOffTitle => t('radar.sub.offTitle');
  String get subOffBody => t('radar.sub.offBody');
  String get subUse => t('radar.sub.use');
  String get subNeedProfile => t('radar.sub.needProfile');
  String get subOnTitle => t('radar.sub.onTitle');
  String get subRefresh => t('radar.sub.refresh');
  String get subConnecting => t('radar.sub.connecting');
  String get subError => t('radar.sub.error');

  // ---- Stats ----
  String get statsLive => t('stats.live');
  String get statsSession => t('stats.session');
  String get statsTotalSession => t('stats.totalSession');
  String get statsSessionTotal => t('stats.sessionTotal');
  String get statsPlanUsage => t('stats.planUsage');
  String get statsExpires => t('stats.expires');
  String get statsMeasuring => t('stats.measuring');
  String get statsLiveLabel => t('stats.liveLabel');
  String get statsDown => t('stats.down');
  String get statsUp => t('stats.up');
  String get statsWorkerUsage => t('stats.workerUsage');
  String get statsRequestsToday => t('stats.requestsToday');
  String get statsWorkerNoData => t('stats.workerNoData');

  // ---- Dashboard extras ----
  String get dashSecure => t('dash.secure');
  String get dashVerifying => t('dash.verifying');
  String get dashError => t('dash.error');
  String get dashLocation => t('dash.location');
  String get dashIp => t('dash.ip');
  String get dashNotProtected => t('dash.notProtected');
  String get dashNotProtectedBody => t('dash.notProtectedBody');
  String get homeTime => t('home.time');
  String get homeData => t('home.data');
  String get homeExpiry => t('home.expiry');
  String get homeSingleConfig => t('home.singleConfig');
  String get cfConnectedTo => t('cf.connectedTo');
  String get cfConnect => t('cf.connect');
  String get toolDeploy => t('tool.deploy');
  String get toolPanel => t('tool.panel');
  String nodesCount(int n) =>
      isFarsi ? '$n نود' : '$n nodes';

  // ---- Settings ----
  String get setGeneral => t('set.general');
  String get setAppearance => t('set.appearance');
  String get setCommunity => t('set.community');
  String get setRouting => t('set.routing');
  String get setRoutingSub => t('set.routingSub');
  String get setRadarSub => t('set.radarSub');
  String get setCloudflare => t('set.cloudflare');
  String get setCloudflareSub => t('set.cloudflareSub');
  String get modeSystem => t('mode.system');
  String get modeDark => t('mode.dark');
  String get modeLight => t('mode.light');

  // ---- Common ----
  String get save => t('common.save');
  String get cancel => t('common.cancel');
  String get reset => t('common.reset');
  String get add => t('common.add');
  String get theme => t('common.theme');
  String get language => t('common.language');
  String get about => t('common.about');
  String get testRealDelay => t('common.testRealDelay');
  String get testing => t('common.testing');

  // ---- Routing ----
  String get routeMode => t('route.mode');
  String get routeModeRule => t('route.modeRule');
  String get routeModeGlobal => t('route.modeGlobal');
  String get routeModeDirect => t('route.modeDirect');
  String get routeModeRuleDesc => t('route.modeRuleDesc');
  String get routeModeGlobalDesc => t('route.modeGlobalDesc');
  String get routeModeDirectDesc => t('route.modeDirectDesc');
  String get routeBlockAds => t('route.blockAds');
  String get routeBlockAdsSub => t('route.blockAdsSub');
  String get routeDirectIran => t('route.directIran');
  String get routeDirectIranSub => t('route.directIranSub');
  String get routeBypassLan => t('route.bypassLan');
  String get routeBypassLanSub => t('route.bypassLanSub');
  String get routeTun => t('route.tun');
  String get routeTunSub => t('route.tunSub');
  String get routeDns => t('route.dns');
  String get routeDnsSub => t('route.dnsSub');
  String get routeApplyNote => t('route.applyNote');

  // ---- Servers ----
  String get serversSearch => t('servers.search');
  String get serversActions => t('servers.actions');
  String get serversSelect => t('servers.select');
  String get serversExtract => t('servers.extract');
  String get serversEdit => t('servers.edit');
  String get serversDelete => t('servers.delete');
  String get serversEmpty => t('servers.empty');
  String get serversEmptySub => t('servers.emptySub');
  String get serversDeploy => t('servers.deploy');
  String get serversDeploySub => t('servers.deploySub');
  String get serversSignIn => t('servers.signIn');
  String get serversSignInSub => t('servers.signInSub');
  String get serversAddConfig => t('servers.addConfig');
  String get serversAddConfigSub => t('servers.addConfigSub');
  String get serversName => t('servers.name');
  String get serversLink => t('servers.link');
  String get serversSubUrl => t('servers.subUrl');
  String get serversUriHint => t('servers.uriHint');
  String get serversScanQr => t('servers.scanQr');
  String get serversScanQrSub => t('servers.scanQrSub');
  String get serversPaste => t('servers.paste');
  String get serversPasteSub => t('servers.pasteSub');
  String get serversManual => t('servers.manual');
  String get serversManualSub => t('servers.manualSub');
  String get serversClipboardEmpty => t('servers.clipboardEmpty');
  String usingProfile(String name) =>
      t('servers.using').replaceFirst('{name}', name);
  String switchingProfile(String name) =>
      t('servers.switching').replaceFirst('{name}', name);

  static const Map<String, String> _en = <String, String>{
    'notice.failoverSwitched':
        'That server was not responding, so Nova switched to the fastest working one.',
    'radar.jitter': 'jitter',
    'radar.loss': 'loss',
    'nav.dashboard': 'Home',
    'nav.profiles': 'Profiles',
    'nav.servers': 'Servers',
    'nav.stats': 'Stats',
    'nav.radar': 'Radar',
    'nav.routing': 'Routing',
    'nav.settings': 'Settings',
    'dash.connect': 'Connect',
    'dash.disconnect': 'Disconnect',
    'dash.connecting': 'Connecting…',
    'dash.connected': 'Connected',
    'dash.disconnected': 'Not connected',
    'dash.tapToConnect': 'Tap to connect',
    'dash.location': 'Location',
    'dash.ip': 'IP',
    'dash.notProtected': 'Not protected',
    'dash.notProtectedBody': 'Connect to route your traffic through Nova.',
    'dash.download': 'Download',
    'dash.upload': 'Upload',
    'home.summary': 'Summary',
    'home.configs': 'Configs',
    'home.title': 'Dashboard',
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
    'radar.sub.offTitle': 'No subscription connected',
    'radar.sub.offBody':
        'Radar will export plain ip:port. Connect your Nova subscription to get '
            'ready-to-import nodes named like the panel.',
    'radar.sub.use': 'Use active subscription',
    'radar.sub.needProfile': 'Add a subscription in Profiles first',
    'radar.sub.onTitle': 'Using subscription',
    'radar.sub.refresh': 'Refresh',
    'radar.sub.connecting': 'Connecting',
    'radar.sub.error': 'Could not load that subscription',
    'stats.live': 'Live',
    'stats.session': 'Session',
    'stats.totalSession': 'Total this session',
    'stats.sessionTotal': 'SESSION TOTAL',
    'stats.planUsage': 'Plan usage',
    'stats.expires': 'Expires',
    'stats.measuring': 'Measuring throughput…',
    'stats.liveLabel': 'LIVE',
    'stats.down': 'Down',
    'stats.up': 'Up',
    'stats.workerUsage': 'Worker usage',
    'stats.requestsToday': 'requests today',
    'stats.workerNoData': 'Connect Cloudflare to see usage',
    'dash.secure': 'Secure',
    'dash.verifying': 'Verifying connection…',
    'dash.error': 'Error',
    'home.time': 'Time',
    'home.data': 'Data',
    'home.expiry': 'Expiry',
    'home.singleConfig': 'Single config',
    'cf.connectedTo': 'Connected to Cloudflare',
    'cf.connect': 'Connect Cloudflare',
    'tool.deploy': 'Deploy',
    'tool.panel': 'Panel',
    'set.general': 'General',
    'set.appearance': 'Appearance',
    'set.community': 'Community',
    'set.routing': 'Routing & DNS',
    'set.routingSub': 'Mode, GeoIP rules, ad blocking, DNS',
    'set.radarSub': 'Scan for clean Cloudflare IPs',
    'set.cloudflare': 'Cloudflare',
    'set.cloudflareSub': 'Deploy or sign in to your panel',
    'mode.system': 'System',
    'mode.dark': 'Dark',
    'mode.light': 'Light',
    'common.save': 'Save',
    'common.cancel': 'Cancel',
    'common.reset': 'Reset',
    'common.add': 'Add',
    'common.theme': 'Theme',
    'common.language': 'Language',
    'common.about': 'About',
    'common.testRealDelay': 'Test real delay',
    'common.testing': 'Testing…',
    'route.mode': 'Mode',
    'route.modeRule': 'Rule-based',
    'route.modeGlobal': 'Global',
    'route.modeDirect': 'Direct',
    'route.modeRuleDesc':
        'Smart routing: proxy what needs it, keep the rest direct.',
    'route.modeGlobalDesc': 'Route all traffic through the proxy.',
    'route.modeDirectDesc': 'No proxying: everything goes direct.',
    'route.blockAds': 'Block ads & trackers',
    'route.blockAdsSub': 'Drops known ad/tracker domains',
    'route.directIran': 'Direct for Iran (GeoIP/GeoSite)',
    'route.directIranSub': 'Iranian destinations bypass the proxy',
    'route.bypassLan': 'Bypass LAN',
    'route.bypassLanSub': 'Private/local ranges stay direct',
    'route.tun': 'Full-device tunnel (TUN)',
    'route.tunSub': 'Route every app, not just proxy-aware ones. Needs '
        'one admin approval when you connect.',
    'route.dns': 'DNS resolver',
    'route.dnsSub': 'Encrypted DNS over HTTPS, resolved through the tunnel.',
    'route.applyNote': 'Changes apply the next time you connect.',
    'servers.search': 'Search servers',
    'servers.actions': 'Actions',
    'servers.select': 'Select',
    'servers.extract': 'Extract configs',
    'servers.edit': 'Edit',
    'servers.delete': 'Delete',
    'servers.empty': 'No servers yet',
    'servers.emptySub':
        'Deploy your own panel, sign in to one, or add a config to get started.',
    'servers.deploy': 'Deploy your own panel',
    'servers.deploySub': 'Spin up a free Nova worker on Cloudflare',
    'servers.signIn': 'Sign in to your panel',
    'servers.signInSub': 'Import configs from an existing panel',
    'servers.addConfig': 'Add a config',
    'servers.addConfigSub': 'Paste a vless:// link or subscription URL',
    'servers.name': 'Name',
    'servers.link': 'Link',
    'servers.subUrl': 'Subscription URL',
    'servers.uriHint': 'vless://…  or  https://…/sub',
    'servers.scanQr': 'Scan QR code',
    'servers.scanQrSub': 'Point the camera at a config QR',
    'servers.paste': 'Paste from clipboard',
    'servers.pasteSub': 'Import a link or subscription you copied',
    'servers.manual': 'Enter manually',
    'servers.manualSub': 'Paste or type a link or subscription URL',
    'servers.clipboardEmpty': 'Clipboard is empty',
    'servers.using': 'Using {name}',
    'servers.switching': 'Switching to {name}',
  };

  static const Map<String, String> _fa = <String, String>{
    'notice.failoverSwitched':
        'این سرور پاسخ نمی‌داد؛ Nova به سریع‌ترین سرور فعال تغییر کرد.',
    'radar.jitter': 'جیتر',
    'radar.loss': 'افت',
    'nav.dashboard': 'خانه',
    'nav.profiles': 'پروفایل‌ها',
    'nav.servers': 'سرورها',
    'nav.stats': 'آمار',
    'nav.radar': 'رادار',
    'nav.routing': 'مسیریابی',
    'nav.settings': 'تنظیمات',
    'dash.connect': 'اتصال',
    'dash.disconnect': 'قطع اتصال',
    'dash.connecting': 'در حال اتصال…',
    'dash.connected': 'متصل شد',
    'dash.disconnected': 'متصل نیست',
    'dash.tapToConnect': 'برای اتصال لمس کنید',
    'dash.location': 'موقعیت',
    'dash.ip': 'آی‌پی',
    'dash.notProtected': 'محافظت‌نشده',
    'dash.notProtectedBody': 'برای عبور ترافیک از Nova متصل شوید.',
    'dash.download': 'دانلود',
    'dash.upload': 'آپلود',
    'home.summary': 'خلاصه',
    'home.configs': 'پیکربندی‌ها',
    'home.title': 'داشبورد',
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
    'radar.sub.offTitle': 'اشتراکی متصل نیست',
    'radar.sub.offBody':
        'رادار فقط ip:port ساده می‌دهد. اشتراک نوای خود را وصل کنید تا نودهای '
            'آماده‌ی ورود با نام‌گذاری پنل بگیرید.',
    'radar.sub.use': 'استفاده از اشتراک فعال',
    'radar.sub.needProfile': 'اول یک اشتراک در پروفایل‌ها اضافه کنید',
    'radar.sub.onTitle': 'در حال استفاده از اشتراک',
    'radar.sub.refresh': 'بازخوانی',
    'radar.sub.connecting': 'در حال اتصال',
    'radar.sub.error': 'بارگیری این اشتراک ممکن نشد',
    'stats.live': 'زنده',
    'stats.session': 'نشست',
    'stats.totalSession': 'مجموع این نشست',
    'stats.sessionTotal': 'مجموع نشست',
    'stats.planUsage': 'مصرف پلن',
    'stats.expires': 'انقضا',
    'stats.measuring': 'در حال اندازه‌گیری…',
    'stats.liveLabel': 'زنده',
    'stats.down': 'دریافت',
    'stats.up': 'ارسال',
    'stats.workerUsage': 'مصرف ورکر',
    'stats.requestsToday': 'درخواست امروز',
    'stats.workerNoData': 'برای دیدن مصرف، کلودفلر را وصل کنید',
    'dash.secure': 'ایمن',
    'dash.verifying': 'در حال بررسی اتصال…',
    'dash.error': 'خطا',
    'home.time': 'زمان',
    'home.data': 'داده',
    'home.expiry': 'انقضا',
    'home.singleConfig': 'پیکربندی تکی',
    'cf.connectedTo': 'متصل به کلودفلر',
    'cf.connect': 'اتصال به کلودفلر',
    'tool.deploy': 'استقرار',
    'tool.panel': 'پنل',
    'set.general': 'عمومی',
    'set.appearance': 'ظاهر',
    'set.community': 'انجمن',
    'set.routing': 'مسیریابی و DNS',
    'set.routingSub': 'حالت، قوانین جغرافیایی، مسدودسازی تبلیغات، DNS',
    'set.radarSub': 'اسکن آی‌پی‌های تمیز کلودفلر',
    'set.cloudflare': 'کلودفلر',
    'set.cloudflareSub': 'استقرار یا ورود به پنل شما',
    'mode.system': 'سیستم',
    'mode.dark': 'تیره',
    'mode.light': 'روشن',
    'common.save': 'ذخیره',
    'common.cancel': 'لغو',
    'common.reset': 'بازنشانی',
    'common.add': 'افزودن',
    'common.theme': 'پوسته',
    'common.language': 'زبان',
    'common.about': 'درباره',
    'common.testRealDelay': 'تست تأخیر واقعی',
    'common.testing': 'در حال تست…',
    'route.mode': 'حالت',
    'route.modeRule': 'قانون‌محور',
    'route.modeGlobal': 'سراسری',
    'route.modeDirect': 'مستقیم',
    'route.modeRuleDesc':
        'مسیریابی هوشمند: هرچه لازم است از پروکسی عبور کند، بقیه مستقیم بماند.',
    'route.modeGlobalDesc': 'همهٔ ترافیک از پروکسی عبور می‌کند.',
    'route.modeDirectDesc': 'بدون پروکسی؛ همه‌چیز مستقیم می‌رود.',
    'route.blockAds': 'مسدودسازی تبلیغات و ردیاب‌ها',
    'route.blockAdsSub': 'دامنه‌های شناخته‌شدهٔ تبلیغ و ردیاب را حذف می‌کند',
    'route.directIran': 'مستقیم برای ایران (GeoIP/GeoSite)',
    'route.directIranSub': 'مقصدهای ایرانی بدون پروکسی عبور می‌کنند',
    'route.bypassLan': 'عبور از شبکهٔ محلی',
    'route.bypassLanSub': 'محدوده‌های خصوصی و محلی مستقیم می‌مانند',
    'route.tun': 'تونل کل دستگاه (TUN)',
    'route.tunSub': 'همهٔ برنامه‌ها را تونل می‌کند، نه فقط برنامه‌های سازگار با '
        'پروکسی. هنگام اتصال به یک‌ بار تأیید مدیر نیاز دارد.',
    'route.dns': 'حل‌کنندهٔ DNS',
    'route.dnsSub': 'DNS رمزگذاری‌شده روی HTTPS که از طریق تونل حل می‌شود.',
    'route.applyNote': 'تغییرات در اتصال بعدی اعمال می‌شوند.',
    'servers.search': 'جستجوی سرورها',
    'servers.actions': 'کنش‌ها',
    'servers.select': 'انتخاب',
    'servers.extract': 'استخراج پیکربندی‌ها',
    'servers.edit': 'ویرایش',
    'servers.delete': 'حذف',
    'servers.empty': 'هنوز سروری نیست',
    'servers.emptySub':
        'برای شروع، پنل خودتان را مستقر کنید، به یک پنل وارد شوید، یا یک پیکربندی اضافه کنید.',
    'servers.deploy': 'پنل خودتان را مستقر کنید',
    'servers.deploySub': 'یک ورکر رایگان نوا روی کلودفلر بسازید',
    'servers.signIn': 'به پنل خود وارد شوید',
    'servers.signInSub': 'پیکربندی‌ها را از یک پنل موجود وارد کنید',
    'servers.addConfig': 'افزودن پیکربندی',
    'servers.addConfigSub': 'یک لینک vless:// یا نشانی اشتراک را بچسبانید',
    'servers.name': 'نام',
    'servers.link': 'لینک',
    'servers.subUrl': 'نشانی اشتراک',
    'servers.uriHint': 'vless://…  یا  https://…/sub',
    'servers.scanQr': 'اسکن کد QR',
    'servers.scanQrSub': 'دوربین را به سمت کد QR پیکربندی بگیرید',
    'servers.paste': 'چسباندن از کلیپ‌بورد',
    'servers.pasteSub': 'لینک یا اشتراکی که کپی کرده‌اید را وارد کنید',
    'servers.manual': 'ورود دستی',
    'servers.manualSub': 'لینک یا نشانی اشتراک را بچسبانید یا تایپ کنید',
    'servers.clipboardEmpty': 'کلیپ‌بورد خالی است',
    'servers.using': 'در حال استفاده از {name}',
    'servers.switching': 'در حال تغییر به {name}',
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
