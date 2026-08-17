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

  /// Shown when the server the user picked connects but carries no traffic.
  /// Nova keeps their choice and tells them, rather than switching behind them.
  String get pinnedExitNoTraffic => t('notice.pinnedExitNoTraffic');

  /// Shown when the pinned server has disappeared from the subscription, so
  /// this session had to auto-select.
  String get pinnedExitGone => t('notice.pinnedExitGone');

  /// Shown when Nova turns on the SNI-block bypass for a subscription because
  /// none of its servers carried traffic.
  String get sniBypassOn => t('notice.sniBypassOn');

  // ---- SNI-block bypass (node list switch) ----
  String get nodeBypassTitle => t('node.bypassTitle');
  String get nodeBypassSub => t('node.bypassSub');

  // ---- Server panel (mini-app webview) ----
  String get panelTitle => t('panel.title');
  String get panelOpen => t('panel.open');
  String get panelOpenSub => t('panel.openSub');

  // ---- SNI-block bypass editor ----
  String get bypassEdit => t('bypass.edit');
  String get bypassEditorTitle => t('bypass.title');
  String get bypassEditorIntro => t('bypass.intro');
  String get bypassFingerprint => t('bypass.fingerprint');
  String get bypassFinalmask => t('bypass.finalmask');
  String get bypassCipherSuites => t('bypass.cipherSuites');
  String get bypassMaskInvalid => t('bypass.maskInvalid');
  String get bypassResetDefaults => t('bypass.reset');
  String get nodeBypassAllBlocked => t('node.bypassAllBlocked');

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
  String get dashNoTraffic => t('dash.noTraffic');
  String get tunnelNoInternet => t('notice.tunnelNoInternet');
  String get dashError => t('dash.error');
  String get dashLocation => t('dash.location');
  String get dashIp => t('dash.ip');
  String get dashPing => t('dash.ping');
  String get dashNotProtected => t('dash.notProtected');
  String get dashNotProtectedBody => t('dash.notProtectedBody');
  String get homeTime => t('home.time');
  String get homeData => t('home.data');
  String get homeExpiry => t('home.expiry');
  String get homeSingleConfig => t('home.singleConfig');

  /// Small banner shown on the dashboard when a newer release exists.
  String get updateAvailable => t('home.updateAvailable');

  /// The action on that banner and in Settings.
  String get updateGet => t('home.updateGet');

  /// The Settings row that re-checks for a new version.
  String get updateCheck => t('settings.checkUpdates');

  /// Label before the address of the server currently carrying traffic.
  String get homeConnectedVia => t('home.connectedVia');

  /// Shown as the connected exit when the auto-selector has not settled on a
  /// specific node yet.
  String get homeConnectedAuto => t('home.connectedAuto');
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
  String get setRelay => t('set.relay');
  String get setRelaySub => t('set.relaySub');
  String get modeSystem => t('mode.system');
  String get modeDark => t('mode.dark');
  String get modeLight => t('mode.light');

  // ---- Google relay ----
  String get relayTitle => t('relay.title');
  String get relayIntro => t('relay.intro');
  String get relayStatusActive => t('relay.statusActive');
  String get relayStatusOff => t('relay.statusOff');
  String get relaySection => t('relay.section');
  String get relayUrlLabel => t('relay.urlLabel');
  String get relayUrlHint => t('relay.urlHint');
  String get relayUrlHelp => t('relay.urlHelp');
  String get relayAuthLabel => t('relay.authLabel');
  String get relayAuthHelp => t('relay.authHelp');
  String get relayInsecureTitle => t('relay.insecureTitle');
  String get relayInsecureSub => t('relay.insecureSub');
  String get relayEnableTitle => t('relay.enableTitle');
  String get relayEnableSub => t('relay.enableSub');
  String get relayTest => t('relay.test');
  String get relayTesting => t('relay.testing');
  String get relayTestOk => t('relay.testOk');
  String get relaySave => t('relay.save');
  String get relaySaved => t('relay.saved');
  String get relayRemove => t('relay.remove');
  String get relayRemoveTitle => t('relay.removeTitle');
  String get relayRemoveBody => t('relay.removeBody');
  String get relayRemoved => t('relay.removed');
  String get relayHowItWorks => t('relay.howItWorks');
  String get relayImport => t('relay.import');
  String get relayShare => t('relay.share');
  String get relayImportedOk => t('relay.importedOk');
  String get relayImportNone => t('relay.importNone');
  String get relayLinkCopied => t('relay.linkCopied');
  String get relayShareTitle => t('relay.shareTitle');
  String get relayShareSub => t('relay.shareSub');
  String get relayNeedUrlToShare => t('relay.needUrlToShare');

  // ---- Speed test ----
  String get speedTitle => t('speed.title');
  String get speedThroughTunnel => t('speed.throughTunnel');
  String get speedDirect => t('speed.direct');
  String get speedDownload => t('speed.download');
  String get speedUpload => t('speed.upload');
  String get speedPing => t('speed.ping');
  String get speedRun => t('speed.run');
  String get speedAgain => t('speed.again');
  String get speedRunning => t('speed.running');
  String get speedPhasePing => t('speed.phasePing');
  String get speedPhaseDown => t('speed.phaseDown');
  String get speedPhaseUp => t('speed.phaseUp');
  String get speedNote => t('speed.note');
  String get speedTest => t('speed.test');
  String get speedTestSub => t('speed.testSub');

  // ---- Find a working setup (connection fixer) ----
  String get fixTitle => t('fix.title');
  String get fixIntroEyebrow => t('fix.introEyebrow');
  String get fixIntroTitle => t('fix.introTitle');
  String get fixIntroBody => t('fix.introBody');
  String get fixNoticeTitle => t('fix.noticeTitle');
  String get fixNoticeBody => t('fix.noticeBody');
  String get fixEstimateLabel => t('fix.estimateLabel');
  String fixEstimateMinutes(int m) =>
      t('fix.estimateMinutes').replaceFirst('%d', '$m');
  String get fixStart => t('fix.start');
  String fixTrying(String fp) => t('fix.trying').replaceFirst('%s', fp);
  String fixApplying(String fp) => t('fix.applying').replaceFirst('%s', fp);
  String fixStepOf(int i, int n) =>
      t('fix.stepOf').replaceFirst('%s', '$i').replaceFirst('%s', '$n');
  String get fixPhaseConnecting => t('fix.phaseConnecting');
  String get fixPhaseChecking => t('fix.phaseChecking');
  String get fixKeepOpen => t('fix.keepOpen');
  String get fixCancel => t('fix.cancel');
  String get fixCancelling => t('fix.cancelling');
  String get fixStepActive => t('fix.stepActive');
  String get fixStepPending => t('fix.stepPending');
  String get fixStepBlocked => t('fix.stepBlocked');
  String get fixTestedEyebrow => t('fix.testedEyebrow');
  String get fixWinnerBadge => t('fix.winnerBadge');
  String get fixSuccessTitle => t('fix.successTitle');
  String get fixSuccessBody => t('fix.successBody');
  String get fixDone => t('fix.done');
  String get fixFailTitle => t('fix.failTitle');
  String get fixFailBody => t('fix.failBody');
  String get fixTryAgain => t('fix.tryAgain');
  String get fixClose => t('fix.close');
  String get fixFpRandomized => t('fix.fpRandomized');
  String get fixDashPrompt => t('fix.dashPrompt');

  // ---- Google relay guide ----
  String get relayGuideTitle => t('relay.guideTitle');
  String get relayGuideWhatTitle => t('relay.guideWhatTitle');
  String get relayGuideWhatBody => t('relay.guideWhatBody');
  String get relayGuideWhyTitle => t('relay.guideWhyTitle');
  String get relayGuideWhyBody => t('relay.guideWhyBody');
  String get relayGuideLimitTitle => t('relay.guideLimitTitle');
  String get relayGuideLimitBody => t('relay.guideLimitBody');
  String get relayGuideStepsTitle => t('relay.guideStepsTitle');
  String get relayGuideStep1 => t('relay.guideStep1');
  String get relayGuideStep2 => t('relay.guideStep2');
  String get relayGuideStep3 => t('relay.guideStep3');
  String get relayGuideStep4 => t('relay.guideStep4');

  // ---- Relay: domain fronting (direct mode) ----
  String get relayFrontTitle => t('relay.frontTitle');
  String get relayFrontSub => t('relay.frontSub');
  String get relayAdvanced => t('relay.advanced');
  String get relayFrontSniLabel => t('relay.frontSniLabel');
  String get relayFrontSniHelp => t('relay.frontSniHelp');
  String get relayFrontIpLabel => t('relay.frontIpLabel');
  String get relayFrontIpHelp => t('relay.frontIpHelp');
  String get relayFrontAuto => t('relay.frontAuto');
  String get relayFrontPicking => t('relay.frontPicking');
  String get relayFrontPicked => t('relay.frontPicked');
  String get relayFrontNone => t('relay.frontNone');
  String get relayTestDirect => t('relay.testDirect');
  String get relayFrontOk => t('relay.frontOk');

  // ---- Relay: full tunnel mode ----
  String get relayTunnelTitle => t('relay.tunnelTitle');
  String get relayTunnelSub => t('relay.tunnelSub');
  String get relayTunnelPortLabel => t('relay.tunnelPortLabel');
  String get relayTunnelPortHelp => t('relay.tunnelPortHelp');
  String get relayTunnelStart => t('relay.tunnelStart');
  String get relayTunnelStop => t('relay.tunnelStop');
  String get relayTunnelStarting => t('relay.tunnelStarting');
  String get relayTunnelRunning => t('relay.tunnelRunning');
  String get relayTunnelStopped => t('relay.tunnelStopped');
  String get relayTunnelTest => t('relay.tunnelTest');
  String get relayTunnelOk => t('relay.tunnelOk');
  String get relayTunnelHint => t('relay.tunnelHint');
  String get relayGuideFrontTitle => t('relay.guideFrontTitle');
  String get relayGuideFrontBody => t('relay.guideFrontBody');
  String get relayGuideTunnelTitle => t('relay.guideTunnelTitle');
  String get relayGuideTunnelBody => t('relay.guideTunnelBody');

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
  String get routeAutoIsp => t('route.autoIsp');
  String get routeAutoIspSub => t('route.autoIspSub');
  String get routeDirectIran => t('route.directIran');
  String get routeDirectIranSub => t('route.directIranSub');
  String get routeBypassLan => t('route.bypassLan');
  String get routeBypassLanSub => t('route.bypassLanSub');
  String get routeTun => t('route.tun');
  String get routeTunSub => t('route.tunSub');
  String get routeDns => t('route.dns');
  String get routeDnsSub => t('route.dnsSub');
  String get routeApplyNote => t('route.applyNote');
  String get routeSpeedTitle => t('route.speedTitle');
  String get routeSpeedSub => t('route.speedSub');
  String get routeSpeedOff => t('route.speedOff');
  String get routeTuneTitle => t('route.tuneTitle');
  String get routeTuneSubtitle => t('route.tuneSubtitle');
  String get routeTuneStatusManual => t('route.tuneStatusManual');
  String get routeTuneStatusManualSub => t('route.tuneStatusManualSub');
  String get routeTuneStatusCarrier => t('route.tuneStatusCarrier');
  String get routeTuneStatusCarrierSub => t('route.tuneStatusCarrierSub');
  String get routeTuneStatusDefault => t('route.tuneStatusDefault');
  String get routeTuneStatusDefaultSub => t('route.tuneStatusDefaultSub');
  String get routeTuneFragOn => t('route.tuneFragOn');
  String get routeTuneFragOff => t('route.tuneFragOff');
  String get routeTunePickerLabel => t('route.tunePickerLabel');
  String get routeTuneAuto => t('route.tuneAuto');
  String get routeTuneRandomized => t('route.tuneRandomized');
  String get routeTunePickerHint => t('route.tunePickerHint');
  String get routeTuneTestHint => t('route.tuneTestHint');

  // ---- Servers ----
  String get serversSearch => t('servers.search');
  String get serversFilterAll => t('servers.filterAll');
  String get serversActions => t('servers.actions');
  String get serversSelect => t('servers.select');
  String get serversExtract => t('servers.extract');
  String get serversEdit => t('servers.edit');
  String get serversDelete => t('servers.delete');
  String get serversEmpty => t('servers.empty');
  String get serversEmptySub => t('servers.emptySub');
  String get serversDeploy => t('servers.deploy');
  String get serversDeploySub => t('servers.deploySub');

  // ---- Deploy via the Telegram bot ----
  String get deployBotTitle => t('deploy.botTitle');
  String get deployBotIntro => t('deploy.botIntro');
  String get deployBotStep1 => t('deploy.botStep1');
  String get deployBotStep2 => t('deploy.botStep2');
  String get deployBotStep3 => t('deploy.botStep3');
  String get deployBotOpen => t('deploy.botOpen');
  String get serversSignIn => t('servers.signIn');
  String get serversSignInSub => t('servers.signInSub');
  String get serversAddConfig => t('servers.addConfig');
  String get serversAddConfigSub => t('servers.addConfigSub');
  String get serversConnectVps => t('servers.connectVps');
  String get serversConnectVpsSub => t('servers.connectVpsSub');
  // Connect-your-VPS flow.
  String get vpsTitle => t('vps.title');
  String get vpsSubtitle => t('vps.subtitle');
  String get vpsManualCard => t('vps.manualCard');
  String get vpsManualCardSub => t('vps.manualCardSub');
  String get vpsSshCard => t('vps.sshCard');
  String get vpsSshCardSub => t('vps.sshCardSub');
  String get vpsManualStep1 => t('vps.manualStep1');
  String get vpsManualStep1Sub => t('vps.manualStep1Sub');
  String get vpsManualStep2 => t('vps.manualStep2');
  String get vpsCopy => t('vps.copy');
  String get vpsCopied => t('vps.copied');
  String get vpsAddress => t('vps.address');
  String get vpsAddressHint => t('vps.addressHint');
  String get vpsAdminPassword => t('vps.adminPassword');
  String get vpsNoDomain => t('vps.noDomain');
  String get vpsNoDomainSub => t('vps.noDomainSub');
  String get vpsConnect => t('vps.connect');
  String get vpsHost => t('vps.host');
  String get vpsHostHint => t('vps.hostHint');
  String get vpsPort => t('vps.port');
  String get vpsSshUser => t('vps.sshUser');
  String get vpsAuthMethod => t('vps.authMethod');
  String get vpsAuthPassword => t('vps.authPassword');
  String get vpsAuthKey => t('vps.authKey');
  String get vpsSshPassword => t('vps.sshPassword');
  String get vpsPrivateKey => t('vps.privateKey');
  String get vpsPrivateKeyHint => t('vps.privateKeyHint');
  String get vpsPassphrase => t('vps.passphrase');
  String get vpsSetAdminPassword => t('vps.setAdminPassword');
  String get vpsSetAdminPasswordSub => t('vps.setAdminPasswordSub');
  String get vpsDomainOptional => t('vps.domainOptional');
  String get vpsSaveCreds => t('vps.saveCreds');
  String get vpsSshWarning => t('vps.sshWarning');
  String get vpsInstall => t('vps.install');
  String get vpsPhaseSshConnecting => t('vps.phaseSshConnecting');
  String get vpsPhaseInstalling => t('vps.phaseInstalling');
  String get vpsPhaseWaiting => t('vps.phaseWaiting');
  String get vpsPhaseLoggingIn => t('vps.phaseLoggingIn');
  String get vpsPhaseImporting => t('vps.phaseImporting');
  String get vpsDoneTitle => t('vps.doneTitle');
  String get vpsDoneSub => t('vps.doneSub');
  String get vpsOpenAdmin => t('vps.openAdmin');
  String get vpsConnectNow => t('vps.connectNow');
  String get vpsFailed => t('vps.failed');
  String get vpsRetry => t('vps.retry');
  // VPS admin panel (users, usage, settings) + manage-anytime.
  String get vpsManage => t('vps.manage');
  String get vpsYourPanels => t('vps.yourPanels');
  String get vpsRemovePanel => t('vps.removePanel');
  String get vpsRemovePanelConfirm => t('vps.removePanelConfirm');
  String get vpsTabUsers => t('vps.tabUsers');
  String get vpsTabSettings => t('vps.tabSettings');
  String get vpsTabInfo => t('vps.tabInfo');
  String get vpsUsers => t('vps.users');
  String get vpsAddUser => t('vps.addUser');
  String get vpsNoUsers => t('vps.noUsers');
  String get vpsUserName => t('vps.userName');
  String get vpsUserEnabled => t('vps.userEnabled');
  String get vpsUserQuota => t('vps.userQuota');
  String get vpsUserQuotaGb => t('vps.userQuotaGb');
  String get vpsUserExpiry => t('vps.userExpiry');
  String get vpsUnlimited => t('vps.unlimited');
  String get vpsNoExpiry => t('vps.noExpiry');
  String get vpsUserUsage => t('vps.userUsage');
  String get vpsEditUser => t('vps.editUser');
  String get vpsDeleteUser => t('vps.deleteUser');
  String get vpsDeleteUserConfirm => t('vps.deleteUserConfirm');
  String get vpsSave => t('vps.save');
  String get vpsCancel => t('vps.cancel');
  String get vpsDelete => t('vps.delete');
  String get vpsShareLink => t('vps.shareLink');
  String get vpsCopyLink => t('vps.copyLink');
  String get vpsShowQr => t('vps.showQr');
  String get vpsQrHint => t('vps.qrHint');
  String get vpsProtocols => t('vps.protocols');
  String get vpsProtocolsSub => t('vps.protocolsSub');
  String get vpsProtoVless => t('vps.protoVless');
  String get vpsProtoVmess => t('vps.protoVmess');
  String get vpsProtoTrojan => t('vps.protoTrojan');
  String get vpsProtoVlessSub => t('vps.protoVlessSub');
  String get vpsProtoVmessSub => t('vps.protoVmessSub');
  String get vpsProtoTrojanSub => t('vps.protoTrojanSub');
  String get vpsProtoAlwaysOn => t('vps.protoAlwaysOn');
  String get vpsSaved => t('vps.saved');
  String get vpsLoadFailed => t('vps.loadFailed');
  String get vpsDomainTitle => t('vps.domainTitle');
  String get vpsDomainSub => t('vps.domainSub');
  String vpsDomainSelfSigned(String host) =>
      t('vps.domainSelfSigned').replaceFirst('{host}', host);
  String vpsDomainTrusted(String host) =>
      t('vps.domainTrusted').replaceFirst('{host}', host);
  String get vpsDomainTrustedPill => t('vps.domainTrustedPill');
  String get vpsDomainField => t('vps.domainField');
  String get vpsDomainMethodAuto => t('vps.domainMethodAuto');
  String get vpsDomainMethodAutoHelp => t('vps.domainMethodAutoHelp');
  String get vpsDomainMethodOrigin => t('vps.domainMethodOrigin');
  String get vpsDomainMethodOriginHelp => t('vps.domainMethodOriginHelp');
  String get vpsDomainCert => t('vps.domainCert');
  String get vpsDomainKey => t('vps.domainKey');
  String get vpsDomainEmail => t('vps.domainEmail');
  String get vpsDomainSetup => t('vps.domainSetup');
  String get vpsDomainWorking => t('vps.domainWorking');
  String get vpsDomainRemove => t('vps.domainRemove');
  String get vpsDomainActive => t('vps.domainActive');
  String get vpsDomainReconnectHint => t('vps.domainReconnectHint');
  String get vpsDomainNeedDomain => t('vps.domainNeedDomain');
  String get vpsDomainFailed => t('vps.domainFailed');

  // ---- VPS overview ----
  String get vpsTabOverview => t('vps.tabOverview');
  String get vpsOvLocation => t('vps.ovLocation');
  String get vpsOvOperational => t('vps.ovOperational');
  String get vpsOvOffline => t('vps.ovOffline');
  String get vpsOvCpu => t('vps.ovCpu');
  String vpsOvCores(int n) => t('vps.ovCores').replaceFirst('{n}', '$n');
  String get vpsOvMemory => t('vps.ovMemory');
  String get vpsOvDisk => t('vps.ovDisk');
  String get vpsOvUptime => t('vps.ovUptime');
  String get vpsOvTraffic => t('vps.ovTraffic');
  String vpsOvToday(String v) => t('vps.ovToday').replaceFirst('{v}', v);
  String get vpsOvNa => t('vps.ovNa');

  // ---- VPS users (extended) ----
  String vpsOnlineCount(int n) =>
      t('vps.onlineCount').replaceFirst('{n}', '$n');
  String get vpsUserNote => t('vps.userNote');
  String get vpsUserDeviceLimit => t('vps.userDeviceLimit');
  String get vpsUserDeviceLimitHint => t('vps.userDeviceLimitHint');
  String get vpsUserDataReset => t('vps.userDataReset');
  String get vpsResetNone => t('vps.resetNone');
  String get vpsResetDay => t('vps.resetDay');
  String get vpsResetWeek => t('vps.resetWeek');
  String get vpsResetMonth => t('vps.resetMonth');
  String get vpsUserExpireDays => t('vps.userExpireDays');
  String get vpsUserExpireDaysHint => t('vps.userExpireDaysHint');

  // ---- VPS settings: routing / DNS / anti-censorship / limits ----
  String get vpsRoutingTitle => t('vps.routingTitle');
  String get vpsRouteBlockAds => t('vps.routeBlockAds');
  String get vpsRouteBypassChina => t('vps.routeBypassChina');
  String get vpsRouteBypassRussia => t('vps.routeBypassRussia');
  String get vpsRouteBypassIran => t('vps.routeBypassIran');
  String get vpsRouteBlockQuic => t('vps.routeBlockQuic');
  String get vpsDnsTitle => t('vps.dnsTitle');
  String get vpsDnsDoh => t('vps.dnsDoh');
  String get vpsDnsProvider => t('vps.dnsProvider');
  String get vpsDnsAntiSanction => t('vps.dnsAntiSanction');
  String get vpsDnsAntiSanctionProvider => t('vps.dnsAntiSanctionProvider');
  String get vpsDnsCustom => t('vps.dnsCustom');
  String get vpsCensorTitle => t('vps.censorTitle');
  String get vpsTlsFragment => t('vps.tlsFragment');
  String get vpsTlsFragOff => t('vps.tlsFragOff');
  String get vpsTlsFragCustom => t('vps.tlsFragCustom');
  String get vpsFragLength => t('vps.fragLength');
  String get vpsFragInterval => t('vps.fragInterval');
  String get vpsFragPackets => t('vps.fragPackets');
  String get vpsLimitsTitle => t('vps.limitsTitle');
  String get vpsLimitMonthlyCap => t('vps.limitMonthlyCap');
  String get vpsLimitSpeed => t('vps.limitSpeed');
  String get vpsChainTitle => t('vps.chainTitle');
  String get vpsChainSub => t('vps.chainSub');
  String get vpsEnforceIpLimit => t('vps.enforceIpLimit');
  String get vpsEnforceIpLimitHint => t('vps.enforceIpLimitHint');

  // ---- VPS settings: WARP ----
  String get vpsWarpTitle => t('vps.warpTitle');
  String get vpsWarpSub => t('vps.warpSub');
  String get vpsWarpRegister => t('vps.warpRegister');
  String get vpsWarpRegistering => t('vps.warpRegistering');
  String get vpsWarpRemove => t('vps.warpRemove');
  String get vpsWarpRegistered => t('vps.warpRegistered');
  String get vpsWarpNoAccount => t('vps.warpNoAccount');
  String get vpsWarpEnable => t('vps.warpEnable');
  String get vpsWarpCalls => t('vps.warpCalls');
  String get vpsWarpMode => t('vps.warpMode');
  String get vpsWarpEndpoint => t('vps.warpEndpoint');
  String get vpsWarpNeedAccount => t('vps.warpNeedAccount');
  String get vpsWarpRegisterFailed => t('vps.warpRegisterFailed');

  // ---- VPS settings: backup & maintenance ----
  String get vpsMaintTitle => t('vps.maintTitle');
  String get vpsMaintSub => t('vps.maintSub');
  String get vpsBackupDownload => t('vps.backupDownload');
  String get vpsBackupCopied => t('vps.backupCopied');
  String get vpsBackupFailed => t('vps.backupFailed');
  String get vpsRestore => t('vps.restore');
  String get vpsRestorePaste => t('vps.restorePaste');
  String get vpsRestoreConfirm => t('vps.restoreConfirm');
  String get vpsRestoreInvalid => t('vps.restoreInvalid');
  String get vpsRestoreDone => t('vps.restoreDone');
  String get vpsRestoreFailed => t('vps.restoreFailed');
  String get vpsUpdateAgent => t('vps.updateAgent');
  String get vpsUpdateAgentConfirm => t('vps.updateAgentConfirm');
  String get vpsUpdateAgentStarted => t('vps.updateAgentStarted');
  String get vpsUpdateAgentFailed => t('vps.updateAgentFailed');

  // ---- VPS settings: Telegram alerts ----
  String get vpsTgTitle => t('vps.tgTitle');
  String get vpsTgSub => t('vps.tgSub');
  String get vpsTgEnable => t('vps.tgEnable');
  String get vpsTgToken => t('vps.tgToken');
  String get vpsTgChatId => t('vps.tgChatId');
  String get vpsTgTest => t('vps.tgTest');
  String get vpsTgTestOk => t('vps.tgTestOk');
  String get vpsTgTestFailed => t('vps.tgTestFailed');

  // ---- VPS subscription formats ----
  String get vpsSubTitle => t('vps.subTitle');
  String get vpsSubSub => t('vps.subSub');
  String get vpsSubBase => t('vps.subBase');
  String get vpsSubClash => t('vps.subClash');
  String get vpsSubSingbox => t('vps.subSingbox');
  String get vpsSubCopied => t('vps.subCopied');

  // ---- VPS inbounds ----
  String get inbTab => t('inb.tab');
  String get inbTitle => t('inb.title');
  String get inbAdd => t('inb.add');
  String get inbNone => t('inb.none');
  String get inbPort => t('inb.port');
  String get inbEdit => t('inb.edit');
  String get inbDelete => t('inb.delete');
  String get inbDeleteConfirm => t('inb.deleteConfirm');
  String get inbEnabled => t('inb.enabled');
  String get inbPublicKey => t('inb.publicKey');
  String get inbCopyKey => t('inb.copyKey');
  String get inbClose => t('inb.close');
  String get inbSecReality => t('inb.secReality');
  String get inbSecTls => t('inb.secTls');
  String get inbSecNone => t('inb.secNone');
  String get inbType => t('inb.type');
  String get inbRemark => t('inb.remark');
  String get inbSniBorrow => t('inb.sniBorrow');
  String get inbSniReal => t('inb.sniReal');
  String get inbSniSuggest => t('inb.sniSuggest');
  String get inbServiceName => t('inb.serviceName');
  String get inbPath => t('inb.path');
  String get inbMode => t('inb.mode');
  String get inbRecommended => t('inb.recommended');
  String get inbKeysAutoNote => t('inb.keysAutoNote');
  String get inbSsAutoNote => t('inb.ssAutoNote');
  String get inbPortInvalid => t('inb.portInvalid');
  String get inbNoteReality => t('inb.noteReality');
  String get inbNoteTls => t('inb.noteTls');
  String get inbNoteTlsInsecure => t('inb.noteTlsInsecure');
  String get inbPublicKeyReady => t('inb.publicKeyReady');
  String get inbPresetRealityVision => t('inb.presetRealityVision');
  String get inbPresetTrojanReality => t('inb.presetTrojanReality');
  String get inbPresetGrpcTls => t('inb.presetGrpcTls');
  String get inbPresetXhttpTls => t('inb.presetXhttpTls');
  String get inbPresetWsTls => t('inb.presetWsTls');
  String get inbPresetSs2022 => t('inb.presetSs2022');
  String get inbPresetRealityVisionSub => t('inb.presetRealityVisionSub');
  String get inbPresetTrojanRealitySub => t('inb.presetTrojanRealitySub');
  String get inbPresetGrpcTlsSub => t('inb.presetGrpcTlsSub');
  String get inbPresetXhttpTlsSub => t('inb.presetXhttpTlsSub');
  String get inbPresetWsTlsSub => t('inb.presetWsTlsSub');
  String get inbPresetSs2022Sub => t('inb.presetSs2022Sub');

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

  // ---- Node list ----
  String get nodeAuto => t('node.auto');
  String get nodeAutoSub => t('node.autoSub');
  String get nodeRefresh => t('node.refresh');
  String get nodeSearch => t('node.search');
  String get nodeClearSearch => t('node.clearSearch');
  String get nodeNoMatch => t('node.noMatch');
  String get nodeFreeTitle => t('node.freeTitle');
  String get nodeFreeBody => t('node.freeBody');
  String get nodeCommunity => t('node.community');
  String nodeCount(int n) => t('node.count').replaceFirst('{n}', '$n');

  /// Verdict on a node whose server never answered.
  String get nodeBlocked => t('node.blocked');

  /// Verdict on a node that cannot be judged without connecting to it.
  String get nodeUntested => t('node.untested');

  /// Verdict on a pool node the core tested through the live tunnel but that
  /// never answered: a dead or unusable exit, not one that "can't be tested".
  String get nodeNoResponse => t('node.noResponse');

  /// Shown when a subscription contained servers Nova cannot run, so the user
  /// learns why the count is short instead of assuming configs went missing.
  String nodeSkipped(int n, String schemes) =>
      t('node.skipped').replaceFirst('{n}', '$n').replaceFirst('{s}', schemes);

  /// Shown when the panel could not be reached to refresh, so the list is the
  /// last saved copy. Reassures the user the servers still work.
  String get nodeStaleList => t('node.staleList');

  // ---- Logs ----
  String get logsTitle => t('logs.title');
  String get logsSubtitle => t('logs.subtitle');
  String get logsTabApp => t('logs.tabApp');
  String get logsTabCore => t('logs.tabCore');
  String get logsEmptyApp => t('logs.emptyApp');
  String get logsEmptyCore => t('logs.emptyCore');
  String get logsCopy => t('logs.copy');
  String get logsCopied => t('logs.copied');
  String get logsClear => t('logs.clear');
  String get logsFollow => t('logs.follow');
  String get logsRedactNote => t('logs.redactNote');
  String get logsVerbose => t('logs.verbose');
  String get logsVerboseSub => t('logs.verboseSub');
  String logsLineCount(int n) =>
      t('logs.lineCount').replaceFirst('{n}', '$n');

  static const Map<String, String> _en = <String, String>{
    'notice.failoverSwitched':
        'That server was not responding, so Nova switched to the fastest working one.',
    'notice.pinnedExitNoTraffic':
        'The server you picked is connected but no traffic is getting through. '
            'Nova is staying on your choice: pick another server, or switch to '
            'Auto, in the server list.',
    'notice.pinnedExitGone':
        'The server you had picked is no longer in this subscription, so Nova '
            'auto-selected one. Open the server list to choose again.',
    'notice.sniBypassOn':
        'None of these servers carried traffic, so Nova turned on the '
            'SNI-block bypass for this subscription and reconnected. You can '
            'turn it off in the server list.',
    'node.bypassTitle': 'SNI-block bypass',
    'node.bypassSub':
        'For networks that block the worker domain itself. Plain TLS with a '
            'fixed cipher list and a fragmented handshake, on the clean-IP '
            'servers only. Slower, so leave it off unless nothing connects.',
    'bypass.edit': 'Edit bypass settings',
    'bypass.title': 'Bypass settings',
    'bypass.intro': 'Advanced. These are the anti-censorship values Nova sends on the clean-IP servers. The defaults are field-tested; change them only if your network starts blocking differently, then Save.',
    'bypass.fingerprint': 'TLS fingerprint',
    'bypass.finalmask': 'Fragmentation (finalmask, JSON)',
    'bypass.cipherSuites': 'Cipher suites (one per line)',
    'bypass.maskInvalid': 'This is not valid JSON.',
    'bypass.reset': 'Reset to defaults',
    'node.bypassAllBlocked':
        'Every server here reads as blocked, which usually means this network '
            'blocks the worker domain. The SNI-block bypass is now on for this '
            'subscription; connect to try it.',
    'notice.tunnelNoInternet':
        'The tunnel is up but no traffic is getting through. Your network may '
            'be blocking this config; scan a clean IP in Radar or try another '
            'config or network.',
    'dash.noTraffic': 'No traffic is getting through',
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
    'dash.ping': 'Ping',
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
    'radar.noResults': 'No clean IPs yet. Start a scan.',
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
    'home.updateAvailable': 'A new version of Nova is available',
    'home.updateGet': 'Get it',
    'settings.checkUpdates': 'Check for updates',
    'home.connectedVia': 'Connected via',
    'home.connectedAuto': 'Auto (picking the fastest)',
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
    'set.relay': 'Google relay',
    'set.relaySub': 'Reach your panel and subscription through Google when it is blocked',
    'relay.title': 'Google relay',
    'relay.intro':
        'Fetch your subscription and reach your panel through Google when your panel\'s domain is blocked.',
    'relay.statusActive': 'Active',
    'relay.statusOff': 'Off',
    'relay.section': 'Relay',
    'relay.urlLabel': 'Relay URL',
    'relay.urlHint': 'https://script.google.com/macros/s/.../exec',
    'relay.urlHelp':
        'The Apps Script /exec URL, or a self-hosted node /relay URL.',
    'relay.authLabel': 'Auth key',
    'relay.authHelp':
        'Optional. The Apps Script usually injects it. Needed for a direct node /relay URL.',
    'relay.insecureTitle': 'Allow insecure certificate',
    'relay.insecureSub':
        'Leave off for the Google relay, which has a valid certificate. Turn on only for a self-hosted node with a self-signed certificate.',
    'relay.enableTitle': 'Enable relay',
    'relay.enableSub':
        'Route subscription and panel fetches through the relay.',
    'relay.test': 'Test connection',
    'relay.testing': 'Testing...',
    'relay.testOk': 'Relay is working',
    'relay.save': 'Save',
    'relay.saved': 'Saved',
    'relay.remove': 'Remove',
    'relay.removeTitle': 'Remove the relay?',
    'relay.removeBody':
        'This clears the relay URL, key, and toggle from this device. You can set it up again anytime.',
    'relay.removed': 'Relay removed',
    'relay.howItWorks': 'How this works',
    'relay.import': 'Import from link',
    'relay.share': 'Share setup',
    'relay.importedOk': 'Relay setup imported',
    'relay.importNone': 'No relay link found on the clipboard',
    'relay.linkCopied': 'Relay link copied',
    'relay.shareTitle': 'Share this relay setup',
    'relay.shareSub':
        'Scan this QR or share the copied link. Anyone who imports it gets your relay URL and key filled in automatically.',
    'relay.needUrlToShare': 'Set the relay URL first, then share it.',
    'speed.title': 'Speed test',
    'speed.throughTunnel':
        'Connected: this measures your real speed through the current config.',
    'speed.direct':
        'Not connected: this measures your direct line. Connect to a config first to test that config.',
    'speed.download': 'Download',
    'speed.upload': 'Upload',
    'speed.ping': 'Ping',
    'speed.run': 'Run test',
    'speed.again': 'Test again',
    'speed.running': 'Testing…',
    'speed.phasePing': 'Pinging…',
    'speed.phaseDown': 'Downloading…',
    'speed.phaseUp': 'Uploading…',
    'speed.note':
        'Tip: connect through one config, test, then switch config (or turn on Speed boost) and test again to see which is fastest on your network.',
    'speed.test': 'Speed test',
    'speed.testSub': 'Measure your real download/upload speed',
    'fix.title': 'Find a working setup',
    'fix.introEyebrow': 'Connection helper',
    'fix.introTitle': 'Test each setup and keep the fastest',
    'fix.introBody':
        'When the block stops your usual setup, Nova tries several TLS fingerprints, measures which ones actually reach the internet, and keeps the fastest.',
    'fix.noticeTitle': 'This can take a few minutes',
    'fix.noticeBody':
        'Nova will reconnect several times while it tests each setup. Keep the app open until it finishes.',
    'fix.estimateLabel': 'Estimated time',
    'fix.estimateMinutes': 'about %d minutes',
    'fix.start': 'Test setups & find the best',
    'fix.trying': 'Testing %s',
    'fix.applying': 'Applying %s…',
    'fix.stepOf': 'Setup %s of %s',
    'fix.phaseConnecting': 'Connecting…',
    'fix.phaseChecking': 'Checking if it gets through…',
    'fix.keepOpen': 'Keep the app open. Nova will reconnect a few times.',
    'fix.cancel': 'Cancel',
    'fix.cancelling': 'Cancelling…',
    'fix.stepActive': 'Testing…',
    'fix.stepPending': 'Waiting',
    'fix.stepBlocked': "Didn't get through",
    'fix.testedEyebrow': 'All setups tested',
    'fix.winnerBadge': 'Best',
    'fix.successTitle': 'Best on your network',
    'fix.successBody': 'Nova will keep using it.',
    'fix.done': 'Done',
    'fix.failTitle': 'No setup got through',
    'fix.failBody':
        'None of the setups got through right now. Try a different server, or set up the Google relay.',
    'fix.tryAgain': 'Try again',
    'fix.close': 'Close',
    'fix.fpRandomized': 'Randomized',
    'fix.dashPrompt':
        "Can't get through? Test the setups and let Nova keep the one that works best.",
    'relay.guideTitle': 'How the Google relay works',
    'relay.guideWhatTitle': 'What it is',
    'relay.guideWhatBody':
        'The relay is a small Google Apps Script that sits in front of your panel. Your device talks to Google. The script forwards the fetch to your Nova worker exit, which fetches the real target and sends the answer back. To your ISP it all looks like ordinary Google traffic.',
    'relay.guideWhyTitle': 'Why it helps',
    'relay.guideWhyBody':
        'If your panel\'s domain (for example a Cloudflare address) is blocked, you normally cannot fetch or refresh your subscription or open your admin panel. With the relay, those fetches go through Google, and Google reaches the blocked host from outside the country, so the config layer keeps working.',
    'relay.guideLimitTitle': 'The honest limit',
    'relay.guideLimitBody':
        'The relay carries the config, not the VPN tunnel. Your actual connection still needs exit nodes that work under the block: a self-hosted VPS with Reality, or a direct IP. Plain Cloudflare-worker nodes still will not connect, even with the relay on. And nothing survives a full internet shutdown where Google is blocked too.',
    'relay.guideStepsTitle': 'Setup steps',
    'relay.guideStep1':
        'In your Nova panel, open the Relay or Tunnel section, generate a key, and copy the Apps Script code.',
    'relay.guideStep2':
        'Deploy it as a Google Apps Script web app: New deployment, type Web app, execute as yourself, access Anyone. Then copy the /exec URL.',
    'relay.guideStep3':
        'Back here, paste the /exec URL (and the key if it asks for one), tap Test, then turn on Enable.',
    'relay.guideStep4':
        'Or point it at your own VPS node\'s /relay URL. Enable the relay in the node panel first. If the node uses a self-signed certificate, turn on Allow insecure certificate.',
    // Domain fronting (direct mode)
    'relay.frontTitle': 'Route via Google edge (domain fronting)',
    'relay.frontSub':
        'Reach the relay even if its own address is DPI-blocked. Nova connects to Google\'s edge and hides the real host inside the encrypted request, so your ISP only sees a connection to www.google.com.',
    'relay.advanced': 'Advanced',
    'relay.frontSniLabel': 'Front name (SNI)',
    'relay.frontSniHelp':
        'The name your ISP sees. www.google.com is safe: blocking it would break Google itself.',
    'relay.frontIpLabel': 'Front edge IP',
    'relay.frontIpHelp':
        'A Google edge IP that routes by host. Leave blank and tap Auto to let Nova pick a live one.',
    'relay.frontAuto': 'Auto-pick a live edge',
    'relay.frontPicking': 'Finding a live Google edge…',
    'relay.frontPicked': 'Front edge ready',
    'relay.frontNone': 'No Google edge answered. Try again on a different network.',
    'relay.testDirect': 'Test direct front',
    'relay.frontOk': 'Domain fronting works',
    // Full tunnel mode
    'relay.tunnelTitle': 'Full tunnel through Google',
    'relay.tunnelSub':
        'Carry real traffic (not just the config) through Google to your own VPS exit. Nova opens a local proxy on this device; point apps or the browser at it. Slow but works when every node is blocked.',
    'relay.tunnelPortLabel': 'Local SOCKS5 port',
    'relay.tunnelPortHelp':
        'Nova listens on 127.0.0.1 at this port. Set your app or system proxy to SOCKS5 127.0.0.1:<port>.',
    'relay.tunnelStart': 'Start tunnel',
    'relay.tunnelStop': 'Stop tunnel',
    'relay.tunnelStarting': 'Starting…',
    'relay.tunnelRunning': 'Tunnel running on 127.0.0.1:',
    'relay.tunnelStopped': 'Tunnel stopped',
    'relay.tunnelTest': 'Test tunnel',
    'relay.tunnelOk': 'Tunnel is carrying traffic',
    'relay.tunnelHint':
        'Needs your VPS node with the tunnel exit enabled, plus the relay above set to a Google Apps Script that forwards to it. Expect low speed: every packet is a request through Google.',
    'relay.guideFrontTitle': 'Direct (domain fronting)',
    'relay.guideFrontBody':
        'For Google-owned hosts and the Apps Script relay itself, Nova can connect straight to Google\'s edge with the name www.google.com while asking for the real host inside the encrypted stream. A DPI box that only allows www.google.com still lets it through, and there is no Apps Script quota on this path. This is what keeps the relay reachable even if script.google.com is blocked.',
    'relay.guideTunnelTitle': 'Full tunnel (last resort)',
    'relay.guideTunnelBody':
        'The full tunnel turns the relay into a real connection: your device opens a local SOCKS5 proxy, and each TCP/UDP flow is carried as requests through Google to your own VPS exit, which talks to the internet. It looks like Google traffic to your ISP and can get you online when every normal node is blocked. It is slow by nature (each chunk is a round-trip through Google) and needs your own VPS with the tunnel exit turned on, so treat it as a last resort, not your daily driver.',
    'mode.system': 'System',
    'mode.dark': 'Dark',
    'mode.light': 'Light',
    'common.save': 'Save',
    'panel.title': 'Server panel',
    'panel.open': 'Open server panel',
    'panel.openSub': 'Manage your Nova panel in the app',
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
    'route.autoIsp': 'Auto-optimize for carrier',
    'route.autoIspSub':
        'Detects your mobile carrier and picks the best fingerprint and fragmentation for it',
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
    'route.speedTitle': 'Speed boost (Hysteria2)',
    'route.speedSub':
        'Turns on Brutal mode for Hysteria2 nodes, which pushes through throttling that slows normal mode. Pick your REAL line speed. Setting it too high can make things worse, so if you are not sure, leave it Off.',
    'route.speedOff': 'Off',
    'route.tuneTitle': 'Anti-censorship (uTLS)',
    'route.tuneSubtitle':
        'The TLS fingerprint your connection wears so it blends in with ordinary web traffic.',
    'route.tuneStatusManual': 'Fingerprint locked to %s',
    'route.tuneStatusManualSub': 'Manual override, used on every network.',
    'route.tuneStatusCarrier': 'Tuned for %s',
    'route.tuneStatusCarrierSub': '%s fingerprint, fragmentation %s.',
    'route.tuneStatusDefault': 'Standard protection',
    'route.tuneStatusDefaultSub': 'Chrome fingerprint, fragmentation on.',
    'route.tuneFragOn': 'on',
    'route.tuneFragOff': 'off',
    'route.tunePickerLabel': 'Override fingerprint',
    'route.tuneAuto': 'Auto',
    'route.tuneRandomized': 'Randomized',
    'route.tunePickerHint':
        'A specific choice overrides the automatic per-carrier pick. Leave it on Auto unless you are testing.',
    'route.tuneTestHint':
        'Not sure which is fastest? Connect, then run a Speed test in the Stats tab with each option.',
    'servers.search': 'Search servers',
    'servers.filterAll': 'All',
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
    'deploy.botTitle': 'Deploy with the Nova bot',
    'deploy.botIntro': 'The Nova Telegram bot sets up a free Nova worker on your own Cloudflare account in a couple of minutes. Nothing to install here.',
    'deploy.botStep1': 'Open the bot and tap Start.',
    'deploy.botStep2': 'Paste a Cloudflare API token when it asks. The bot uses it once to create the worker on your account.',
    'deploy.botStep3': 'It gives you your panel link and password. Come back and use "Import from your panel" to sign in.',
    'deploy.botOpen': 'Open the Nova bot',
    'servers.signIn': 'Sign in to your panel',
    'servers.signInSub': 'Import configs from an existing panel',
    'servers.addConfig': 'Add a config',
    'servers.addConfigSub': 'Paste a vless:// link or subscription URL',
    'servers.connectVps': 'Connect your VPS',
    'servers.connectVpsSub': 'Run the Nova panel on your own server',
    'vps.title': 'Connect your VPS',
    'vps.subtitle': 'Run the full Nova panel on your own server and manage it '
        'right here.',
    'vps.manualCard': "I'll run the command myself",
    'vps.manualCardSub': 'Paste one line on your VPS, then connect to it.',
    'vps.sshCard': 'Install it for me',
    'vps.sshCardSub': 'Nova connects over SSH and sets everything up.',
    'vps.manualStep1': 'Run this on your VPS',
    'vps.manualStep1Sub': 'Sign in to your server over SSH and paste this. It '
        'installs the Nova agent.',
    'vps.manualStep2': 'Then connect to it',
    'vps.copy': 'Copy',
    'vps.copied': 'Copied',
    'vps.address': 'VPS address',
    'vps.addressHint': 'domain or IP, e.g. node.example.com',
    'vps.adminPassword': 'Admin password',
    'vps.noDomain': 'My server has no domain',
    'vps.noDomainSub': 'Connect straight to the IP with a self-signed '
        'certificate.',
    'vps.connect': 'Connect',
    'vps.host': 'Server IP or host',
    'vps.hostHint': 'e.g. 203.0.113.10 or node.example.com',
    'vps.port': 'SSH port',
    'vps.sshUser': 'SSH username',
    'vps.authMethod': 'Authentication',
    'vps.authPassword': 'Password',
    'vps.authKey': 'SSH key',
    'vps.sshPassword': 'SSH password',
    'vps.privateKey': 'Private key (PEM)',
    'vps.privateKeyHint': 'Paste the contents of your private key file',
    'vps.passphrase': 'Key passphrase (optional)',
    'vps.setAdminPassword': 'Panel admin password',
    'vps.setAdminPasswordSub': "You'll use this to sign in to the panel.",
    'vps.domainOptional': 'Domain (optional)',
    'vps.saveCreds': 'Save these credentials on this device',
    'vps.sshWarning': 'Your SSH credentials are used once to install the agent. '
        'They are only kept if you choose to save them, and stay in this '
        "device's secure storage.",
    'vps.install': 'Install & connect',
    'vps.phaseSshConnecting': 'Connecting over SSH…',
    'vps.phaseInstalling': 'Installing the Nova agent…',
    'vps.phaseWaiting': 'Waiting for the agent…',
    'vps.phaseLoggingIn': 'Signing in to the panel…',
    'vps.phaseImporting': 'Importing your node…',
    'vps.doneTitle': 'Your VPS is connected',
    'vps.doneSub': 'The node was added to your servers.',
    'vps.openAdmin': 'Open admin panel',
    'vps.connectNow': 'Connect now',
    'vps.failed': 'Something went wrong',
    'vps.retry': 'Try again',
    'vps.manage': 'Manage',
    'vps.yourPanels': 'Your VPS panels',
    'vps.removePanel': 'Remove',
    'vps.removePanelConfirm': 'Remove this VPS from the app? The server keeps '
        'running; only the saved connection is forgotten here.',
    'vps.tabUsers': 'Users',
    'vps.tabSettings': 'Settings',
    'vps.tabInfo': 'Info',
    'vps.users': 'Users',
    'vps.addUser': 'Add user',
    'vps.noUsers': 'No users yet. Add one to share access.',
    'vps.userName': 'Name',
    'vps.userEnabled': 'Enabled',
    'vps.userQuota': 'Data limit',
    'vps.userQuotaGb': 'Data limit (GB, 0 = unlimited)',
    'vps.userExpiry': 'Expiry date',
    'vps.unlimited': 'Unlimited',
    'vps.noExpiry': 'No expiry',
    'vps.userUsage': 'Used',
    'vps.editUser': 'Edit user',
    'vps.deleteUser': 'Delete user',
    'vps.deleteUserConfirm': 'Delete this user? Their access stops immediately.',
    'vps.save': 'Save',
    'vps.cancel': 'Cancel',
    'vps.delete': 'Delete',
    'vps.shareLink': 'Share link',
    'vps.copyLink': 'Copy link',
    'vps.showQr': 'QR code',
    'vps.qrHint': 'Scan in the Nova app to import this user.',
    'vps.protocols': 'Protocols',
    'vps.protocolsSub': 'Which protocols this server offers. The app measures '
        'them and auto-picks the fastest one that works.',
    'vps.protoVless': 'VLESS',
    'vps.protoVmess': 'VMess',
    'vps.protoTrojan': 'Trojan',
    'vps.protoVlessSub': 'Fast and modern',
    'vps.protoVmessSub': 'Broad client compatibility',
    'vps.protoTrojanSub': 'Blends in as normal HTTPS',
    'vps.protoAlwaysOn': 'Always on',
    'vps.saved': 'Saved',
    'vps.loadFailed': 'Could not load. Pull to retry.',
    'vps.domainTitle': 'Domain & TLS',
    'vps.domainSub': 'Put this node on your own domain with a trusted '
        'certificate, so clients connect without a security warning.',
    'vps.domainSelfSigned':
        'This node uses a self-signed certificate on {host}.',
    'vps.domainTrusted': 'Trusted certificate active for {host}.',
    'vps.domainTrustedPill': 'Trusted',
    'vps.domainField': 'Domain',
    'vps.domainMethodAuto': 'Automatic (Let\'s Encrypt)',
    'vps.domainMethodAutoHelp': 'Needs port 80 open and this domain\'s DNS '
        'pointing at the server.',
    'vps.domainMethodOrigin': 'Paste Cloudflare Origin Certificate',
    'vps.domainMethodOriginHelp':
        'Use this when the domain sits behind Cloudflare.',
    'vps.domainCert': 'Certificate',
    'vps.domainKey': 'Private key',
    'vps.domainEmail': 'Email (optional)',
    'vps.domainSetup': 'Set up domain',
    'vps.domainWorking': 'Working…',
    'vps.domainRemove': 'Remove domain',
    'vps.domainActive': 'Domain is active.',
    'vps.domainReconnectHint':
        'You may need to reconnect using the new address.',
    'vps.domainNeedDomain': 'Enter a domain first.',
    'vps.domainFailed': 'Could not set up the domain.',
    'vps.tabOverview': 'Overview',
    'vps.ovLocation': 'Location',
    'vps.ovOperational': 'Operational',
    'vps.ovOffline': 'Offline',
    'vps.ovCpu': 'CPU',
    'vps.ovCores': '{n} cores',
    'vps.ovMemory': 'Memory',
    'vps.ovDisk': 'Disk',
    'vps.ovUptime': 'Uptime',
    'vps.ovTraffic': 'Traffic',
    'vps.ovToday': 'Today {v}',
    'vps.ovNa': 'n/a',
    'vps.onlineCount': '{n} online',
    'vps.userNote': 'Note',
    'vps.userDeviceLimit': 'Device limit',
    'vps.userDeviceLimitHint': '0 = unlimited',
    'vps.userDataReset': 'Data reset',
    'vps.resetNone': 'None',
    'vps.resetDay': 'Daily',
    'vps.resetWeek': 'Weekly',
    'vps.resetMonth': 'Monthly',
    'vps.userExpireDays': 'Expire N days after first connect',
    'vps.userExpireDaysHint': '0 = off',
    'vps.routingTitle': 'Routing',
    'vps.routeBlockAds': 'Block ads',
    'vps.routeBypassChina': 'Bypass China',
    'vps.routeBypassRussia': 'Bypass Russia',
    'vps.routeBypassIran': 'Bypass Iran (domestic sites)',
    'vps.routeBlockQuic': 'Block QUIC',
    'vps.dnsTitle': 'Secure DNS',
    'vps.dnsDoh': 'Encrypted DNS (DoH)',
    'vps.dnsProvider': 'DoH provider',
    'vps.dnsAntiSanction': 'Anti-sanction DNS',
    'vps.dnsAntiSanctionProvider': 'Anti-sanction provider',
    'vps.dnsCustom': 'Custom DNS',
    'vps.censorTitle': 'Anti-censorship',
    'vps.tlsFragment': 'TLS fragment',
    'vps.tlsFragOff': 'Off',
    'vps.tlsFragCustom': 'Custom',
    'vps.fragLength': 'Fragment length',
    'vps.fragInterval': 'Fragment interval',
    'vps.fragPackets': 'Packets',
    'vps.limitsTitle': 'Limits',
    'vps.limitMonthlyCap': 'Monthly cap (GB, 0 = off)',
    'vps.limitSpeed': 'Speed limit (KB/s, 0 = off)',
    'vps.chainTitle': 'Chain proxy',
    'vps.chainSub': 'Route exits through another proxy. One socks5://host:port '
        'or http://host:port per line.',
    'vps.enforceIpLimit': 'Enforce device limits',
    'vps.enforceIpLimitHint': 'Over-limit users are briefly cut off.',
    'vps.warpTitle': 'WARP',
    'vps.warpSub': 'Route exits through Cloudflare WARP. Register a free '
        'account first.',
    'vps.warpRegister': 'Register free account',
    'vps.warpRegistering': 'Registering, this can take a few seconds…',
    'vps.warpRemove': 'Remove account',
    'vps.warpRegistered': 'Account ready',
    'vps.warpNoAccount': 'No account yet',
    'vps.warpEnable': 'Use WARP',
    'vps.warpCalls': 'WARP for calls',
    'vps.warpMode': 'WARP mode',
    'vps.warpEndpoint': 'Endpoint (optional)',
    'vps.warpNeedAccount': 'Register a free WARP account before turning it on.',
    'vps.warpRegisterFailed':
        'Could not register a WARP account. Try again in a moment.',
    'vps.maintTitle': 'Backup & maintenance',
    'vps.maintSub': 'Copy a full settings backup, or restore one you saved '
        'earlier.',
    'vps.backupDownload': 'Copy backup',
    'vps.backupCopied': 'Backup JSON copied to the clipboard.',
    'vps.backupFailed': 'Could not create a backup.',
    'vps.restore': 'Restore',
    'vps.restorePaste': 'Paste backup JSON',
    'vps.restoreConfirm':
        'Restore from this backup? It replaces the current settings.',
    'vps.restoreInvalid': 'That is not valid backup JSON.',
    'vps.restoreDone': 'Backup restored.',
    'vps.restoreFailed': 'Could not restore the backup.',
    'vps.updateAgent': 'Update agent',
    'vps.updateAgentConfirm':
        'Update the node agent now? The node restarts briefly and reconnects.',
    'vps.updateAgentStarted': 'Update started. The node will restart shortly.',
    'vps.updateAgentFailed': 'Could not start the update.',
    'vps.tgTitle': 'Telegram alerts',
    'vps.tgSub': 'Get a Telegram message when a user hits their quota, expires, '
        'or goes over the device limit.',
    'vps.tgEnable': 'Enable Telegram alerts',
    'vps.tgToken': 'Bot token',
    'vps.tgChatId': 'Chat ID',
    'vps.tgTest': 'Send test message',
    'vps.tgTestOk': 'Test message sent.',
    'vps.tgTestFailed': 'Could not send the test message.',
    'vps.subTitle': 'Subscription',
    'vps.subSub': 'Share this node with any client. Pick the format your client '
        'uses.',
    'vps.subBase': 'Base64 (default)',
    'vps.subClash': 'Clash',
    'vps.subSingbox': 'sing-box',
    'vps.subCopied': 'Subscription link copied.',
    'inb.tab': 'Inbounds',
    'inb.title': 'Inbounds',
    'inb.add': 'Add inbound',
    'inb.none': 'No inbounds yet. Add one to offer advanced Xray protocols.',
    'inb.port': 'Port',
    'inb.edit': 'Edit inbound',
    'inb.delete': 'Delete inbound',
    'inb.deleteConfirm':
        'Delete this inbound? Clients using it stop connecting.',
    'inb.enabled': 'Enabled',
    'inb.publicKey': 'Public key',
    'inb.copyKey': 'Copy public key',
    'inb.close': 'Close',
    'inb.secReality': 'REALITY',
    'inb.secTls': 'TLS',
    'inb.secNone': 'none',
    'inb.type': 'Type',
    'inb.remark': 'Name (optional)',
    'inb.sniBorrow': 'Borrow a site name (SNI)',
    'inb.sniReal': 'SNI (your real domain)',
    'inb.sniSuggest': 'Suggestions',
    'inb.serviceName': 'gRPC service name',
    'inb.path': 'Path',
    'inb.mode': 'XHTTP mode',
    'inb.recommended': 'Recommended',
    'inb.keysAutoNote':
        'Reality keys and a short ID are generated on the server. The public '
            'key shows here after you save.',
    'inb.ssAutoNote': 'The server password is generated automatically.',
    'inb.portInvalid': 'Enter a port between 1 and 65535.',
    'inb.noteReality':
        'Reality works best on port 443, but the front already uses 443, so '
            'this inbound runs on a different port. Some strict networks may '
            'block non-443 ports.',
    'inb.noteTls': 'TLS types need a real domain with a trusted certificate.',
    'inb.noteTlsInsecure':
        'This node uses a self-signed certificate, so clients will need to '
            'allow insecure connections.',
    'inb.publicKeyReady':
        'Inbound saved. Share this Reality public key with clients.',
    'inb.presetRealityVision': 'Reality + Vision',
    'inb.presetTrojanReality': 'Trojan + Reality',
    'inb.presetGrpcTls': 'gRPC + TLS',
    'inb.presetXhttpTls': 'XHTTP + TLS',
    'inb.presetWsTls': 'WebSocket + TLS',
    'inb.presetSs2022': 'Shadowsocks-2022',
    'inb.presetRealityVisionSub':
        'Best all-round. Looks like a visit to a real HTTPS site.',
    'inb.presetTrojanRealitySub': 'Trojan wrapped in Reality camouflage.',
    'inb.presetGrpcTlsSub': 'gRPC transport over standard TLS.',
    'inb.presetXhttpTlsSub': 'HTTP-based transport over TLS.',
    'inb.presetWsTlsSub': 'WebSocket over TLS.',
    'inb.presetSs2022Sub': 'Modern Shadowsocks with a strong cipher.',
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
    'node.auto': 'Auto (fastest)',
    'node.autoSub': 'Let Nova pick the lowest-latency node',
    'node.refresh': 'Refresh',
    'node.search': 'Search nodes',
    'node.clearSearch': 'Clear search',
    'node.noMatch': 'No nodes match your search',
    'node.freeTitle': 'Nova is free',
    'node.freeBody':
        'Never pay anyone for these configs. Nova is a free service, share it with friends.',
    'node.community': 'Follow Nova',
    'node.count': '{n} nodes',
    'node.blocked': 'blocked',
    'node.untested': 'not testable',
    'node.noResponse': 'no response',
    'node.staleList':
        'Could not refresh from the panel, so these are your saved servers. '
            'They still work; connect and they will update on their own.',
    'node.skipped':
        '{n} server(s) in this subscription use something Nova cannot run ({s}), so they are not listed.',
    'logs.title': 'Logs',
    'logs.subtitle': 'What Nova and the VPN core are doing',
    'logs.tabApp': 'Nova',
    'logs.tabCore': 'Core',
    'logs.emptyApp':
        'Nothing yet. Connect once and the steps Nova takes appear here.',
    'logs.emptyCore':
        'Nothing yet. The core writes here while the tunnel is running.',
    'logs.copy': 'Copy',
    'logs.copied': 'Copied. Credentials were removed.',
    'logs.clear': 'Clear',
    'logs.follow': 'Follow new lines',
    'logs.redactNote':
        'Passwords, UUIDs and subscription tokens are removed when you copy. '
            'Server addresses are kept, because they are usually what the '
            'problem turns on.',
    'logs.verbose': 'Detailed core log',
    'logs.verboseSub':
        'Log every connection the core routes, not just its warnings. Uses more '
            'battery, and starts with your next connection.',
    'logs.lineCount': '{n} lines',
  };

  static const Map<String, String> _fa = <String, String>{
    'notice.failoverSwitched':
        'این سرور پاسخ نمی‌داد؛ Nova به سریع‌ترین سرور فعال تغییر کرد.',
    'notice.pinnedExitNoTraffic':
        'سروری که انتخاب کرده‌اید وصل شده ولی هیچ ترافیکی عبور نمی‌کند. '
            '\u2066Nova\u2069 روی انتخاب شما می‌ماند: از فهرست سرورها سرور '
            'دیگری را انتخاب کنید یا حالت خودکار را بزنید.',
    'notice.pinnedExitGone':
        'سروری که انتخاب کرده بودید دیگر در این اشتراک نیست، پس '
            '\u2066Nova\u2069 به‌صورت خودکار یکی را انتخاب کرد. برای انتخاب '
            'دوباره فهرست سرورها را باز کنید.',
    'notice.sniBypassOn':
        'هیچ‌کدام از این سرورها ترافیک عبور ندادند، پس \u2066Nova\u2069 '
            'دور زدن مسدودی \u2066SNI\u2069 را برای این اشتراک روشن کرد و '
            'دوباره وصل شد. می‌توانید از فهرست سرورها خاموشش کنید.',
    'node.bypassTitle': 'دور زدن مسدودی \u2066SNI\u2069',
    'node.bypassSub':
        'برای شبکه‌هایی که خود دامنه‌ی ورکر را می‌بندند. \u2066TLS\u2069 ساده '
            'با فهرست رمز ثابت و دست‌دهی تکه‌تکه‌شده، فقط روی سرورهای '
            'آی‌پی تمیز. کندتر است؛ فقط وقتی هیچ‌چیز وصل نمی‌شود روشنش کنید.',
    'bypass.edit': 'ویرایش تنظیمات بایپس',
    'bypass.title': 'تنظیمات بایپس',
    'bypass.intro': 'پیشرفته. این‌ها مقادیر ضدسانسوری هستند که نوا روی سرورهای Clean-IP می‌فرستد. پیش‌فرض‌ها آزمایش‌شده‌اند؛ فقط اگر شیوه‌ی فیلترینگ شبکه‌تان تغییر کرد آن‌ها را عوض و ذخیره کنید.',
    'bypass.fingerprint': 'اثر انگشت TLS',
    'bypass.finalmask': 'فرگمنت (finalmask، JSON)',
    'bypass.cipherSuites': 'مجموعه رمزها (هر خط یکی)',
    'bypass.maskInvalid': 'این JSON معتبر نیست.',
    'bypass.reset': 'بازگردانی به پیش‌فرض',
    'node.bypassAllBlocked':
        'همه‌ی سرورهای اینجا مسدود دیده می‌شوند که معمولا یعنی این شبکه دامنه‌ی '
            'ورکر را می‌بندد. دور زدن مسدودی \u2066SNI\u2069 برای این اشتراک '
            'روشن شد؛ وصل شوید تا امتحان شود.',
    'notice.tunnelNoInternet':
        'تونل وصل شده ولی هیچ ترافیکی عبور نمی‌کند. احتمالا شبکه شما این کانفیگ '
            'را مسدود کرده؛ در رادار یک IP تمیز اسکن کنید یا کانفیگ یا شبکه '
            'دیگری را امتحان کنید.',
    'dash.noTraffic': 'ترافیکی عبور نمی‌کند',
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
    'dash.ping': 'پینگ',
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
    'radar.noResults': 'هنوز آی‌پی تمیزی نیست. اسکن را شروع کنید.',
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
    'home.updateAvailable': 'نسخه‌ی جدید نوا در دسترس است',
    'home.updateGet': 'دریافت',
    'settings.checkUpdates': 'بررسی بروزرسانی',
    'home.connectedVia': 'متصل از طریق',
    'home.connectedAuto': 'خودکار (انتخاب سریع‌ترین)',
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
    'set.relay': 'رله گوگل',
    'set.relaySub': 'وقتی پنل و اشتراکتان مسدود است، از طریق گوگل به آن‌ها برسید',
    'relay.title': 'رله گوگل',
    'relay.intro':
        'وقتی دامنه‌ی پنلتان مسدود است، اشتراک خود را از طریق گوگل بگیرید و به پنلتان برسید.',
    'relay.statusActive': 'فعال',
    'relay.statusOff': 'خاموش',
    'relay.section': 'رله',
    'relay.urlLabel': 'آدرس رله',
    'relay.urlHint': 'https://script.google.com/macros/s/.../exec',
    'relay.urlHelp':
        'آدرس exec/ اسکریپت گوگل، یا آدرس relay/ یک نود خودمیزبان.',
    'relay.authLabel': 'کلید احراز',
    'relay.authHelp':
        'اختیاری. اسکریپت گوگل معمولا خودش آن را تزریق می‌کند. برای آدرس relay/ مستقیم روی نود لازم است.',
    'relay.insecureTitle': 'اجازه‌ی گواهی نامعتبر',
    'relay.insecureSub':
        'برای رله گوگل که گواهی معتبر دارد خاموش بگذارید. فقط برای نود خودمیزبان با گواهی خودامضا روشن کنید.',
    'relay.enableTitle': 'فعال‌سازی رله',
    'relay.enableSub': 'گرفتن اشتراک و ارتباط با پنل را از مسیر رله عبور بده.',
    'relay.test': 'تست اتصال',
    'relay.testing': 'در حال تست...',
    'relay.testOk': 'رله کار می‌کند',
    'relay.save': 'ذخیره',
    'relay.saved': 'ذخیره شد',
    'relay.remove': 'حذف',
    'relay.removeTitle': 'رله حذف شود؟',
    'relay.removeBody':
        'این کار آدرس، کلید و کلید فعال‌سازی رله را از این دستگاه پاک می‌کند. هر وقت خواستید می‌توانید دوباره تنظیمش کنید.',
    'relay.removed': 'رله حذف شد',
    'relay.howItWorks': 'این چطور کار می‌کند',
    'relay.import': 'وارد کردن از لینک',
    'relay.share': 'اشتراک‌گذاری تنظیمات',
    'relay.importedOk': 'تنظیمات رله وارد شد',
    'relay.importNone': 'لینک رله‌ای در کلیپ‌بورد پیدا نشد',
    'relay.linkCopied': 'لینک رله کپی شد',
    'relay.shareTitle': 'این تنظیمات رله را به اشتراک بگذار',
    'relay.shareSub':
        'این QR را اسکن کن یا لینک کپی‌شده را بفرست. هرکس آن را وارد کند، آدرس و کلید رله‌ات خودکار پر می‌شود.',
    'relay.needUrlToShare': 'اول آدرس رله را وارد کن، بعد به اشتراک بگذار.',
    'speed.title': 'تست سرعت',
    'speed.throughTunnel':
        'متصل هستی: این سرعت واقعی تو را از مسیر کانفیگ فعلی اندازه می‌گیرد.',
    'speed.direct':
        'متصل نیستی: این سرعت خط مستقیم تو را می‌سنجد. اول به یک کانفیگ وصل شو تا آن را تست کنی.',
    'speed.download': 'دانلود',
    'speed.upload': 'آپلود',
    'speed.ping': 'پینگ',
    'speed.run': 'اجرای تست',
    'speed.again': 'تست دوباره',
    'speed.running': 'در حال تست…',
    'speed.phasePing': 'در حال پینگ…',
    'speed.phaseDown': 'در حال دانلود…',
    'speed.phaseUp': 'در حال آپلود…',
    'speed.note':
        'نکته: به یک کانفیگ وصل شو و تست بگیر، بعد کانفیگ را عوض کن (یا افزایش سرعت را روشن کن) و دوباره تست بگیر تا ببینی کدام روی شبکه‌ات سریع‌تر است.',
    'speed.test': 'تست سرعت',
    'speed.testSub': 'سرعت واقعی دانلود/آپلودت را بسنج',
    'fix.title': 'یافتن یک روش کارآمد',
    'fix.introEyebrow': 'دستیار اتصال',
    'fix.introTitle': 'همه روش‌ها را بسنج و سریع‌ترین را نگه دار',
    'fix.introBody':
        'وقتی فیلترینگ جلوی روش همیشگی‌ات را می‌گیرد، نوا چند اثرانگشت TLS را امتحان می‌کند، می‌سنجد کدام‌ها واقعاً به اینترنت می‌رسند و سریع‌ترین را نگه می‌دارد.',
    'fix.noticeTitle': 'این کار ممکن است چند دقیقه طول بکشد',
    'fix.noticeBody':
        'نوا هنگام آزمایش هر روش چند بار دوباره وصل می‌شود. تا پایان کار، برنامه را باز نگه دار.',
    'fix.estimateLabel': 'زمان تقریبی',
    'fix.estimateMinutes': 'حدود %d دقیقه',
    'fix.start': 'آزمایش روش‌ها و یافتن بهترین',
    'fix.trying': 'در حال آزمایش %s',
    'fix.applying': 'در حال اعمال %s…',
    'fix.stepOf': 'روش %s از %s',
    'fix.phaseConnecting': 'در حال اتصال…',
    'fix.phaseChecking': 'بررسی عبور از فیلترینگ…',
    'fix.keepOpen': 'برنامه را باز نگه دار. نوا چند بار دوباره وصل می‌شود.',
    'fix.cancel': 'لغو',
    'fix.cancelling': 'در حال لغو…',
    'fix.stepActive': 'در حال تست…',
    'fix.stepPending': 'در نوبت',
    'fix.stepBlocked': 'عبور نکرد',
    'fix.testedEyebrow': 'همه روش‌ها آزمایش شد',
    'fix.winnerBadge': 'بهترین',
    'fix.successTitle': 'بهترین روش روی شبکه‌ات',
    'fix.successBody': 'نوا از همین استفاده می‌کند.',
    'fix.done': 'تمام',
    'fix.failTitle': 'هیچ روشی عبور نکرد',
    'fix.failBody':
        'در حال حاضر هیچ‌کدام از روش‌ها عبور نکردند. یک سرور دیگر را امتحان کن، یا رله گوگل را راه‌اندازی کن.',
    'fix.tryAgain': 'تلاش دوباره',
    'fix.close': 'بستن',
    'fix.fpRandomized': 'تصادفی',
    'fix.dashPrompt':
        'عبور نمی‌کنی؟ روش‌ها را بسنج و بگذار نوا بهترینی که جواب می‌دهد را نگه دارد.',
    'relay.guideTitle': 'رله گوگل چطور کار می‌کند',
    'relay.guideWhatTitle': 'این چیست',
    'relay.guideWhatBody':
        'رله یک اسکریپت کوچک گوگل (Apps Script) است که جلوی پنل شما می‌نشیند. دستگاه شما فقط با گوگل حرف می‌زند. اسکریپت درخواست را به خروجی ورکر نوای شما می‌فرستد، و آن ورکر مقصد واقعی را می‌گیرد و پاسخ را برمی‌گرداند. برای اپراتور شما همه‌ی این‌ها مثل ترافیک عادی گوگل به نظر می‌رسد.',
    'relay.guideWhyTitle': 'چرا کمک می‌کند',
    'relay.guideWhyBody':
        'اگر دامنه‌ی پنلتان (مثلا یک آدرس کلودفلر) مسدود باشد، معمولا نمی‌توانید اشتراک خود را بگیرید یا تازه کنید یا پنل مدیریت را باز کنید. با رله، این درخواست‌ها از مسیر گوگل عبور می‌کنند و گوگل از بیرون کشور به میزبان مسدودشده می‌رسد، پس لایه‌ی کانفیگ کار می‌کند.',
    'relay.guideLimitTitle': 'محدودیت واقعی',
    'relay.guideLimitBody':
        'رله فقط کانفیگ را عبور می‌دهد، نه خود تونل وی‌پی‌ان. اتصال واقعی شما همچنان به نودهای خروجی نیاز دارد که زیر فیلترینگ کار کنند: یک وی‌پی‌اس خودمیزبان با Reality، یا یک آی‌پی مستقیم. نودهای ساده‌ی ورکر کلودفلر حتی با رله روشن هم وصل نمی‌شوند. و هیچ‌چیز از قطع کامل اینترنت که گوگل هم مسدود باشد جان سالم به در نمی‌برد.',
    'relay.guideStepsTitle': 'مراحل راه‌اندازی',
    'relay.guideStep1':
        'در پنل نوای خود، بخش رله یا تونل را باز کنید، یک کلید بسازید و کد Apps Script را کپی کنید.',
    'relay.guideStep2':
        'آن را به عنوان وب‌اپ گوگل منتشر کنید: New deployment، نوع Web app، اجرا با حساب خودتان، دسترسی Anyone. سپس آدرس exec/ را کپی کنید.',
    'relay.guideStep3':
        'به اینجا برگردید، آدرس exec/ را (و اگر خواسته شد کلید را) بچسبانید، تست را بزنید، و بعد فعال‌سازی را روشن کنید.',
    'relay.guideStep4':
        'یا آن را به آدرس relay/ نود وی‌پی‌اس خودتان وصل کنید. اول رله را در پنل نود روشن کنید. اگر نود گواهی خودامضا دارد، اجازه‌ی گواهی نامعتبر را روشن کنید.',
    // Domain fronting (direct mode)
    'relay.frontTitle': 'عبور از لبه‌ی گوگل (Domain Fronting)',
    'relay.frontSub':
        'حتی اگر آدرس خود رله مسدود باشد به آن برس. نوا به لبه‌ی گوگل وصل می‌شود و میزبان واقعی را داخل درخواست رمزنگاری‌شده پنهان می‌کند، پس اپراتور فقط اتصال به www.google.com را می‌بیند.',
    'relay.advanced': 'پیشرفته',
    'relay.frontSniLabel': 'نام نمایشی (SNI)',
    'relay.frontSniHelp':
        'نامی که اپراتور می‌بیند. www.google.com امن است: مسدودکردنش کل گوگل را از کار می‌اندازد.',
    'relay.frontIpLabel': 'آی‌پی لبه',
    'relay.frontIpHelp':
        'یک آی‌پی لبه‌ی گوگل که بر اساس میزبان مسیریابی می‌کند. خالی بگذارید و «انتخاب خودکار» را بزنید تا نوا یکی زنده پیدا کند.',
    'relay.frontAuto': 'انتخاب خودکار لبه‌ی زنده',
    'relay.frontPicking': 'در حال یافتن لبه‌ی زنده‌ی گوگل…',
    'relay.frontPicked': 'لبه آماده شد',
    'relay.frontNone': 'هیچ لبه‌ی گوگلی پاسخ نداد. روی شبکه‌ی دیگری امتحان کنید.',
    'relay.testDirect': 'تست فرانتینگ مستقیم',
    'relay.frontOk': 'دامین فرانتینگ کار می‌کند',
    // Full tunnel mode
    'relay.tunnelTitle': 'تونل کامل از مسیر گوگل',
    'relay.tunnelSub':
        'ترافیک واقعی (نه فقط کانفیگ) را از مسیر گوگل به خروجی وی‌پی‌اس خودتان ببر. نوا یک پراکسی محلی روی این دستگاه باز می‌کند؛ اپ‌ها یا مرورگر را به آن وصل کنید. کند است اما وقتی همه‌ی نودها مسدودند کار می‌کند.',
    'relay.tunnelPortLabel': 'پورت SOCKS5 محلی',
    'relay.tunnelPortHelp':
        'نوا روی 127.0.0.1 و این پورت گوش می‌دهد. پراکسی اپ یا سیستم را روی SOCKS5 127.0.0.1:<port> بگذارید.',
    'relay.tunnelStart': 'شروع تونل',
    'relay.tunnelStop': 'توقف تونل',
    'relay.tunnelStarting': 'در حال شروع…',
    'relay.tunnelRunning': 'تونل روی 127.0.0.1: در حال اجراست',
    'relay.tunnelStopped': 'تونل متوقف شد',
    'relay.tunnelTest': 'تست تونل',
    'relay.tunnelOk': 'تونل ترافیک را عبور می‌دهد',
    'relay.tunnelHint':
        'به نود وی‌پی‌اس شما با خروجی تونل روشن نیاز دارد، به‌علاوه‌ی رله‌ی بالا که به یک Apps Script گوگل وصل باشد و به آن فوروارد کند. سرعت پایین است: هر بسته یک درخواست از مسیر گوگل است.',
    'relay.guideFrontTitle': 'مستقیم (دامین فرانتینگ)',
    'relay.guideFrontBody':
        'برای میزبان‌های متعلق به گوگل و خود رله‌ی Apps Script، نوا می‌تواند مستقیم با نام www.google.com به لبه‌ی گوگل وصل شود و میزبان واقعی را داخل جریان رمزنگاری‌شده بخواهد. جعبه‌ی DPI که فقط www.google.com را مجاز می‌داند باز هم اجازه‌ی عبور می‌دهد و روی این مسیر سهمیه‌ی Apps Script مصرف نمی‌شود. همین باعث می‌شود رله حتی وقتی script.google.com مسدود است در دسترس بماند.',
    'relay.guideTunnelTitle': 'تونل کامل (آخرین راه‌حل)',
    'relay.guideTunnelBody':
        'تونل کامل رله را به یک اتصال واقعی تبدیل می‌کند: دستگاه شما یک پراکسی SOCKS5 محلی باز می‌کند و هر جریان TCP/UDP به‌صورت درخواست‌هایی از مسیر گوگل به خروجی وی‌پی‌اس خودتان حمل می‌شود و آن خروجی با اینترنت حرف می‌زند. برای اپراتور مثل ترافیک گوگل به نظر می‌رسد و می‌تواند وقتی همه‌ی نودهای معمول مسدودند شما را آنلاین کند. ذاتا کند است (هر تکه یک رفت‌وبرگشت از مسیر گوگل است) و به وی‌پی‌اس خودتان با خروجی تونل روشن نیاز دارد، پس آن را آخرین راه‌حل بدانید نه گزینه‌ی روزمره.',
    'mode.system': 'سیستم',
    'mode.dark': 'تیره',
    'mode.light': 'روشن',
    'common.save': 'ذخیره',
    'panel.title': 'پنل سرور',
    'panel.open': 'باز کردن پنل سرور',
    'panel.openSub': 'پنل نوای خود را داخل برنامه مدیریت کنید',
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
    'route.autoIsp': 'بهینه‌سازی خودکار برای اپراتور',
    'route.autoIspSub':
        'اپراتور همراه شما را تشخیص می‌دهد و بهترین اثر انگشت و تکه‌سازی را برای آن انتخاب می‌کند',
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
    'route.speedTitle': 'افزایش سرعت (Hysteria2)',
    'route.speedSub':
        'حالت Brutal را برای نودهای Hysteria2 روشن می‌کند که از محدودسازی سرعت (throttling) عبور می‌کند. سرعت واقعی خط اینترنتت را انتخاب کن. تنظیم خیلی زیاد می‌تواند بدترش کند، پس اگر مطمئن نیستی روی خاموش بگذار.',
    'route.speedOff': 'خاموش',
    'route.tuneTitle': 'ضد سانسور (uTLS)',
    'route.tuneSubtitle':
        'اثر انگشت TLS که اتصال شما به تن می‌کند تا میان ترافیک عادی وب دیده نشود.',
    'route.tuneStatusManual': 'اثر انگشت روی %s قفل شده',
    'route.tuneStatusManualSub': 'انتخاب دستی، روی همهٔ شبکه‌ها اعمال می‌شود.',
    'route.tuneStatusCarrier': 'تنظیم‌شده برای %s',
    'route.tuneStatusCarrierSub': 'اثر انگشت %s، تکه‌سازی %s.',
    'route.tuneStatusDefault': 'محافظت استاندارد',
    'route.tuneStatusDefaultSub': 'اثر انگشت Chrome، تکه‌سازی روشن.',
    'route.tuneFragOn': 'روشن',
    'route.tuneFragOff': 'خاموش',
    'route.tunePickerLabel': 'بازنویسی اثر انگشت',
    'route.tuneAuto': 'خودکار',
    'route.tuneRandomized': 'تصادفی',
    'route.tunePickerHint':
        'انتخاب یک گزینهٔ مشخص، انتخاب خودکار بر اساس اپراتور را کنار می‌گذارد. اگر در حال آزمایش نیستی، روی خودکار بگذار.',
    'route.tuneTestHint':
        'مطمئن نیستی کدام سریع‌تر است؟ وصل شو و در تب آمار با هر گزینه یک تست سرعت بگیر.',
    'servers.search': 'جستجوی سرورها',
    'servers.filterAll': 'همه',
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
    'deploy.botTitle': 'استقرار با ربات نوا',
    'deploy.botIntro': 'ربات تلگرام نوا در چند دقیقه یک ورکر رایگان نوا روی حساب \u2066Cloudflare\u2069 خودتان می‌سازد. اینجا چیزی نصب نمی‌شود.',
    'deploy.botStep1': 'ربات را باز کنید و \u2066Start\u2069 را بزنید.',
    'deploy.botStep2': 'وقتی خواست، یک توکن \u2066Cloudflare API\u2069 را بفرستید. ربات یک‌بار از آن برای ساخت ورکر روی حساب شما استفاده می‌کند.',
    'deploy.botStep3': 'لینک پنل و رمز را به شما می‌دهد. برگردید و از «ورود از پنل» وارد شوید.',
    'deploy.botOpen': 'باز کردن ربات نوا',
    'servers.signIn': 'به پنل خود وارد شوید',
    'servers.signInSub': 'پیکربندی‌ها را از یک پنل موجود وارد کنید',
    'servers.addConfig': 'افزودن پیکربندی',
    'servers.addConfigSub': 'یک لینک vless:// یا نشانی اشتراک را بچسبانید',
    'servers.connectVps': 'اتصال سرور مجازی شما',
    'servers.connectVpsSub': 'پنل کامل نوا را روی سرور خودت اجرا کن',
    'vps.title': 'اتصال سرور مجازی شما',
    'vps.subtitle': 'پنل کامل نوا را روی سرور خودت اجرا کن و همین‌جا مدیریتش کن.',
    'vps.manualCard': 'خودم دستور را اجرا می‌کنم',
    'vps.manualCardSub': 'یک خط را روی سرورت بچسبان، بعد وصل شو.',
    'vps.sshCard': 'برایم نصبش کن',
    'vps.sshCardSub': 'نوا از طریق SSH وصل می‌شود و همه‌چیز را راه می‌اندازد.',
    'vps.manualStep1': 'این را روی سرورت اجرا کن',
    'vps.manualStep1Sub':
        'با SSH به سرورت وارد شو و این را بچسبان. عامل نوا را نصب می‌کند.',
    'vps.manualStep2': 'بعد به آن وصل شو',
    'vps.copy': 'کپی',
    'vps.copied': 'کپی شد',
    'vps.address': 'نشانی سرور',
    'vps.addressHint': 'دامنه یا آی‌پی، مثل node.example.com',
    'vps.adminPassword': 'رمز مدیر',
    'vps.noDomain': 'سرورم دامنه ندارد',
    'vps.noDomainSub': 'با گواهی خودامضا مستقیم به آی‌پی وصل شو.',
    'vps.connect': 'اتصال',
    'vps.host': 'آی‌پی یا هاست سرور',
    'vps.hostHint': 'مثل 203.0.113.10 یا node.example.com',
    'vps.port': 'پورت SSH',
    'vps.sshUser': 'نام کاربری SSH',
    'vps.authMethod': 'احراز هویت',
    'vps.authPassword': 'رمز عبور',
    'vps.authKey': 'کلید SSH',
    'vps.sshPassword': 'رمز SSH',
    'vps.privateKey': 'کلید خصوصی (PEM)',
    'vps.privateKeyHint': 'محتوای فایل کلید خصوصی‌ات را بچسبان',
    'vps.passphrase': 'عبارت عبور کلید (اختیاری)',
    'vps.setAdminPassword': 'رمز مدیر پنل',
    'vps.setAdminPasswordSub': 'با این رمز وارد پنل می‌شوی.',
    'vps.domainOptional': 'دامنه (اختیاری)',
    'vps.saveCreds': 'این اطلاعات ورود روی این دستگاه ذخیره شود',
    'vps.sshWarning':
        'اطلاعات SSH فقط یک‌بار برای نصب عامل استفاده می‌شود. تنها در صورت '
        'انتخاب تو ذخیره می‌شود و در حافظهٔ امن همین دستگاه می‌ماند.',
    'vps.install': 'نصب و اتصال',
    'vps.phaseSshConnecting': 'در حال اتصال از طریق SSH…',
    'vps.phaseInstalling': 'در حال نصب عامل نوا…',
    'vps.phaseWaiting': 'در انتظار عامل…',
    'vps.phaseLoggingIn': 'در حال ورود به پنل…',
    'vps.phaseImporting': 'در حال وارد کردن نودت…',
    'vps.doneTitle': 'سرور مجازی‌ات وصل شد',
    'vps.doneSub': 'نود به فهرست سرورهایت اضافه شد.',
    'vps.openAdmin': 'باز کردن پنل مدیریت',
    'vps.connectNow': 'همین حالا وصل شو',
    'vps.failed': 'مشکلی پیش آمد',
    'vps.retry': 'دوباره تلاش کن',
    'vps.manage': 'مدیریت',
    'vps.yourPanels': 'پنل‌های سرور تو',
    'vps.removePanel': 'حذف',
    'vps.removePanelConfirm': 'این سرور از برنامه حذف شود؟ سرور همچنان کار '
        'می‌کند؛ فقط اتصال ذخیره‌شده اینجا فراموش می‌شود.',
    'vps.tabUsers': 'کاربران',
    'vps.tabSettings': 'تنظیمات',
    'vps.tabInfo': 'اطلاعات',
    'vps.users': 'کاربران',
    'vps.addUser': 'افزودن کاربر',
    'vps.noUsers': 'هنوز کاربری نیست. یکی اضافه کن تا دسترسی را به اشتراک بگذاری.',
    'vps.userName': 'نام',
    'vps.userEnabled': 'فعال',
    'vps.userQuota': 'محدودیت داده',
    'vps.userQuotaGb': 'محدودیت داده (گیگابایت، ۰ = نامحدود)',
    'vps.userExpiry': 'تاریخ انقضا',
    'vps.unlimited': 'نامحدود',
    'vps.noExpiry': 'بدون انقضا',
    'vps.userUsage': 'مصرف‌شده',
    'vps.editUser': 'ویرایش کاربر',
    'vps.deleteUser': 'حذف کاربر',
    'vps.deleteUserConfirm': 'این کاربر حذف شود؟ دسترسی‌اش فوراً قطع می‌شود.',
    'vps.save': 'ذخیره',
    'vps.cancel': 'لغو',
    'vps.delete': 'حذف',
    'vps.shareLink': 'لینک اشتراک',
    'vps.copyLink': 'کپی لینک',
    'vps.showQr': 'کد QR',
    'vps.qrHint': 'برای وارد کردن این کاربر، در برنامهٔ نوا اسکن کن.',
    'vps.protocols': 'پروتکل‌ها',
    'vps.protocolsSub': 'این سرور چه پروتکل‌هایی ارائه می‌دهد. برنامه آن‌ها را '
        'می‌سنجد و سریع‌ترین گزینهٔ کارآمد را خودکار انتخاب می‌کند.',
    'vps.protoVless': 'VLESS',
    'vps.protoVmess': 'VMess',
    'vps.protoTrojan': 'Trojan',
    'vps.protoVlessSub': 'سریع و مدرن',
    'vps.protoVmessSub': 'سازگاری گسترده با کلاینت‌ها',
    'vps.protoTrojanSub': 'شبیه HTTPS معمولی',
    'vps.protoAlwaysOn': 'همیشه روشن',
    'vps.saved': 'ذخیره شد',
    'vps.loadFailed': 'بارگذاری نشد. برای تلاش دوباره بکش.',
    'vps.domainTitle': 'دامنه و TLS',
    'vps.domainSub': 'این نود را روی دامنهٔ خودت با گواهی معتبر بگذار تا '
        'کلاینت‌ها بدون هشدار امنیتی وصل شوند.',
    'vps.domainSelfSigned': 'این نود روی {host} از گواهی خودامضا استفاده می‌کند.',
    'vps.domainTrusted': 'گواهی معتبر برای {host} فعال است.',
    'vps.domainTrustedPill': 'معتبر',
    'vps.domainField': 'دامنه',
    'vps.domainMethodAuto': 'خودکار (Let\'s Encrypt)',
    'vps.domainMethodAutoHelp': 'به پورت ۸۰ باز و اشاره‌کردن DNS این دامنه به '
        'سرور نیاز دارد.',
    'vps.domainMethodOrigin': 'چسباندن گواهی Origin کلادفلر',
    'vps.domainMethodOriginHelp': 'زمانی که دامنه پشت کلادفلر است از این استفاده کن.',
    'vps.domainCert': 'گواهی',
    'vps.domainKey': 'کلید خصوصی',
    'vps.domainEmail': 'ایمیل (اختیاری)',
    'vps.domainSetup': 'راه‌اندازی دامنه',
    'vps.domainWorking': 'در حال انجام…',
    'vps.domainRemove': 'حذف دامنه',
    'vps.domainActive': 'دامنه فعال است.',
    'vps.domainReconnectHint': 'شاید لازم باشد با نشانی جدید دوباره وصل شوی.',
    'vps.domainNeedDomain': 'ابتدا یک دامنه وارد کن.',
    'vps.domainFailed': 'راه‌اندازی دامنه ممکن نشد.',
    'vps.tabOverview': 'نمای کلی',
    'vps.ovLocation': 'موقعیت',
    'vps.ovOperational': 'در حال کار',
    'vps.ovOffline': 'خاموش',
    'vps.ovCpu': 'پردازنده',
    'vps.ovCores': '{n} هسته',
    'vps.ovMemory': 'حافظه',
    'vps.ovDisk': 'دیسک',
    'vps.ovUptime': 'مدت روشن‌بودن',
    'vps.ovTraffic': 'ترافیک',
    'vps.ovToday': 'امروز {v}',
    'vps.ovNa': 'نامشخص',
    'vps.onlineCount': '{n} آنلاین',
    'vps.userNote': 'یادداشت',
    'vps.userDeviceLimit': 'محدودیت دستگاه',
    'vps.userDeviceLimitHint': '۰ = نامحدود',
    'vps.userDataReset': 'بازنشانی داده',
    'vps.resetNone': 'بدون',
    'vps.resetDay': 'روزانه',
    'vps.resetWeek': 'هفتگی',
    'vps.resetMonth': 'ماهانه',
    'vps.userExpireDays': 'انقضا N روز پس از اولین اتصال',
    'vps.userExpireDaysHint': '۰ = خاموش',
    'vps.routingTitle': 'مسیریابی',
    'vps.routeBlockAds': 'مسدودکردن تبلیغات',
    'vps.routeBypassChina': 'دورزدن چین',
    'vps.routeBypassRussia': 'دورزدن روسیه',
    'vps.routeBypassIran': 'دورزدن ایران (سایت‌های داخلی)',
    'vps.routeBlockQuic': 'مسدودکردن QUIC',
    'vps.dnsTitle': 'DNS امن',
    'vps.dnsDoh': 'DNS رمزنگاری‌شده (DoH)',
    'vps.dnsProvider': 'ارائه‌دهندهٔ DoH',
    'vps.dnsAntiSanction': 'DNS ضدتحریم',
    'vps.dnsAntiSanctionProvider': 'ارائه‌دهندهٔ ضدتحریم',
    'vps.dnsCustom': 'DNS سفارشی',
    'vps.censorTitle': 'ضدسانسور',
    'vps.tlsFragment': 'تکه‌تکه‌کردن TLS',
    'vps.tlsFragOff': 'خاموش',
    'vps.tlsFragCustom': 'سفارشی',
    'vps.fragLength': 'طول تکه',
    'vps.fragInterval': 'فاصلهٔ تکه',
    'vps.fragPackets': 'بسته‌ها',
    'vps.limitsTitle': 'محدودیت‌ها',
    'vps.limitMonthlyCap': 'سقف ماهانه (گیگابایت، ۰ = خاموش)',
    'vps.limitSpeed': 'محدودیت سرعت (کیلوبایت بر ثانیه، ۰ = خاموش)',
    'vps.chainTitle': 'پروکسی زنجیره‌ای',
    'vps.chainSub': 'خروجی را از یک پروکسی دیگر عبور بده. در هر خط یک '
        'socks5://host:port یا http://host:port.',
    'vps.enforceIpLimit': 'اعمال محدودیت دستگاه',
    'vps.enforceIpLimitHint': 'کاربران بیش از حد مجاز برای مدتی کوتاه قطع می‌شوند.',
    'vps.warpTitle': 'WARP',
    'vps.warpSub': 'خروجی را از Cloudflare WARP عبور بده. ابتدا یک حساب رایگان '
        'ثبت کن.',
    'vps.warpRegister': 'ثبت حساب رایگان',
    'vps.warpRegistering': 'در حال ثبت، ممکن است چند ثانیه طول بکشد…',
    'vps.warpRemove': 'حذف حساب',
    'vps.warpRegistered': 'حساب آماده است',
    'vps.warpNoAccount': 'هنوز حسابی نیست',
    'vps.warpEnable': 'استفاده از WARP',
    'vps.warpCalls': 'WARP برای تماس‌ها',
    'vps.warpMode': 'حالت WARP',
    'vps.warpEndpoint': 'نقطهٔ اتصال (اختیاری)',
    'vps.warpNeedAccount': 'پیش از روشن‌کردن، یک حساب رایگان WARP ثبت کن.',
    'vps.warpRegisterFailed':
        'ثبت حساب WARP ممکن نشد. کمی بعد دوباره تلاش کن.',
    'vps.maintTitle': 'پشتیبان‌گیری و نگهداری',
    'vps.maintSub': 'یک پشتیبان کامل از تنظیمات را کپی کن، یا یکی را که قبلاً '
        'ذخیره کرده‌ای بازگردان.',
    'vps.backupDownload': 'کپی پشتیبان',
    'vps.backupCopied': 'JSON پشتیبان در کلیپ‌بورد کپی شد.',
    'vps.backupFailed': 'ساخت پشتیبان ممکن نشد.',
    'vps.restore': 'بازگردانی',
    'vps.restorePaste': 'JSON پشتیبان را بچسبان',
    'vps.restoreConfirm':
        'از این پشتیبان بازگردانی شود؟ تنظیمات فعلی جایگزین می‌شود.',
    'vps.restoreInvalid': 'این یک JSON پشتیبان معتبر نیست.',
    'vps.restoreDone': 'پشتیبان بازگردانده شد.',
    'vps.restoreFailed': 'بازگردانی پشتیبان ممکن نشد.',
    'vps.updateAgent': 'به‌روزرسانی عامل',
    'vps.updateAgentConfirm':
        'عامل نود همین حالا به‌روزرسانی شود؟ نود برای مدتی کوتاه راه‌اندازی مجدد '
            'می‌شود و دوباره وصل می‌گردد.',
    'vps.updateAgentStarted': 'به‌روزرسانی شروع شد. نود به‌زودی راه‌اندازی مجدد می‌شود.',
    'vps.updateAgentFailed': 'شروع به‌روزرسانی ممکن نشد.',
    'vps.tgTitle': 'هشدارهای تلگرام',
    'vps.tgSub': 'وقتی کاربری به سقف مصرفش می‌رسد، منقضی می‌شود، یا از محدودیت '
        'دستگاه عبور می‌کند، یک پیام تلگرام بگیر.',
    'vps.tgEnable': 'روشن‌کردن هشدارهای تلگرام',
    'vps.tgToken': 'توکن ربات',
    'vps.tgChatId': 'شناسهٔ چت',
    'vps.tgTest': 'ارسال پیام آزمایشی',
    'vps.tgTestOk': 'پیام آزمایشی ارسال شد.',
    'vps.tgTestFailed': 'ارسال پیام آزمایشی ممکن نشد.',
    'vps.subTitle': 'اشتراک',
    'vps.subSub': 'این نود را با هر کلاینتی به اشتراک بگذار. قالبی را که '
        'کلاینتت استفاده می‌کند انتخاب کن.',
    'vps.subBase': 'Base64 (پیش‌فرض)',
    'vps.subClash': 'Clash',
    'vps.subSingbox': 'sing-box',
    'vps.subCopied': 'لینک اشتراک کپی شد.',
    'inb.tab': 'ورودی‌ها',
    'inb.title': 'ورودی‌ها',
    'inb.add': 'افزودن ورودی',
    'inb.none':
        'هنوز ورودی‌ای نیست. یکی اضافه کن تا پروتکل‌های پیشرفتهٔ Xray را ارائه دهی.',
    'inb.port': 'پورت',
    'inb.edit': 'ویرایش ورودی',
    'inb.delete': 'حذف ورودی',
    'inb.deleteConfirm':
        'این ورودی حذف شود؟ کلاینت‌هایی که از آن استفاده می‌کنند دیگر وصل نمی‌شوند.',
    'inb.enabled': 'فعال',
    'inb.publicKey': 'کلید عمومی',
    'inb.copyKey': 'کپی کلید عمومی',
    'inb.close': 'بستن',
    'inb.secReality': 'REALITY',
    'inb.secTls': 'TLS',
    'inb.secNone': 'بدون',
    'inb.type': 'نوع',
    'inb.remark': 'نام (اختیاری)',
    'inb.sniBorrow': 'قرض‌گرفتن نام یک سایت (SNI)',
    'inb.sniReal': 'SNI (دامنهٔ واقعی تو)',
    'inb.sniSuggest': 'پیشنهادها',
    'inb.serviceName': 'نام سرویس gRPC',
    'inb.path': 'مسیر',
    'inb.mode': 'حالت XHTTP',
    'inb.recommended': 'پیشنهادی',
    'inb.keysAutoNote':
        'کلیدهای Reality و یک shortID روی سرور ساخته می‌شوند. کلید عمومی پس از '
            'ذخیره اینجا نشان داده می‌شود.',
    'inb.ssAutoNote': 'رمز سرور به‌طور خودکار ساخته می‌شود.',
    'inb.portInvalid': 'یک پورت بین ۱ تا ۶۵۵۳۵ وارد کن.',
    'inb.noteReality':
        'Reality روی پورت ۴۴۳ بهترین عملکرد را دارد، اما فرانت همین حالا ۴۴۳ را '
            'گرفته، پس این ورودی روی پورت دیگری اجرا می‌شود. برخی شبکه‌های '
            'سخت‌گیر ممکن است پورت‌های غیر ۴۴۳ را مسدود کنند.',
    'inb.noteTls': 'نوع‌های TLS به یک دامنهٔ واقعی با گواهی معتبر نیاز دارند.',
    'inb.noteTlsInsecure':
        'این نود از گواهی خودامضا استفاده می‌کند، پس کلاینت‌ها باید اتصال ناامن '
            'را مجاز کنند.',
    'inb.publicKeyReady':
        'ورودی ذخیره شد. این کلید عمومی Reality را با کلاینت‌ها به اشتراک بگذار.',
    'inb.presetRealityVision': 'Reality + Vision',
    'inb.presetTrojanReality': 'Trojan + Reality',
    'inb.presetGrpcTls': 'gRPC + TLS',
    'inb.presetXhttpTls': 'XHTTP + TLS',
    'inb.presetWsTls': 'WebSocket + TLS',
    'inb.presetSs2022': 'Shadowsocks-2022',
    'inb.presetRealityVisionSub':
        'بهترین گزینهٔ همه‌کاره. مثل بازدید از یک سایت واقعی HTTPS دیده می‌شود.',
    'inb.presetTrojanRealitySub': 'تروجان پیچیده در استتار Reality.',
    'inb.presetGrpcTlsSub': 'انتقال gRPC روی TLS استاندارد.',
    'inb.presetXhttpTlsSub': 'انتقال مبتنی بر HTTP روی TLS.',
    'inb.presetWsTlsSub': 'وب‌سوکت روی TLS.',
    'inb.presetSs2022Sub': 'شادوساکس مدرن با رمز قوی.',
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
    'node.auto': 'خودکار (سریع‌ترین)',
    'node.autoSub': 'نوا سریع‌ترین سرور را انتخاب می‌کند',
    'node.refresh': 'بازخوانی',
    'node.search': 'جستجوی سرور',
    'node.clearSearch': 'پاک کردن جستجو',
    'node.noMatch': 'سروری با جستجوی شما پیدا نشد',
    'node.freeTitle': 'نوا رایگان است',
    'node.freeBody':
        'برای این کانفیگ‌ها به کسی پول ندهید. نوا یک سرویس رایگان است، آن را با دوستانتان به اشتراک بگذارید.',
    'node.community': 'نوا را دنبال کنید',
    'node.count': '{n} سرور',
    'node.blocked': 'مسدود',
    'node.untested': 'قابل تست نیست',
    'node.noResponse': 'بدون پاسخ',
    'node.staleList':
        'به‌روزرسانی از پنل ممکن نشد، پس این‌ها سرورهای ذخیره‌شده‌ی شما هستند. '
            'هنوز کار می‌کنند؛ وصل شوید تا خودشان به‌روز شوند.',
    'node.skipped':
        '{n} سرور در این اشتراک از چیزی استفاده می‌کنند که نوا نمی‌تواند اجرا کند (\u2066{s}\u2069)، پس فهرست نشده‌اند.',
    'logs.title': 'گزارش‌ها',
    'logs.subtitle': 'آنچه نوا و هسته‌ی VPN انجام می‌دهند',
    'logs.tabApp': 'نوا',
    'logs.tabCore': 'هسته',
    'logs.emptyApp':
        'هنوز چیزی نیست. یک بار وصل شوید تا کارهایی که نوا انجام می‌دهد '
            'اینجا بیاید.',
    'logs.emptyCore':
        'هنوز چیزی نیست. هسته تا وقتی تونل روشن است اینجا می‌نویسد.',
    'logs.copy': 'کپی',
    'logs.copied': 'کپی شد. اطلاعات محرمانه حذف شد.',
    'logs.clear': 'پاک کردن',
    'logs.follow': 'دنبال‌کردن خط‌های تازه',
    'logs.redactNote':
        'رمزها، \u2066UUID\u2069 و توکن اشتراک هنگام کپی حذف می‌شوند. '
            'آدرس سرورها می‌ماند، چون معمولا مشکل به همان‌ها برمی‌گردد.',
    'logs.verbose': 'گزارش کامل هسته',
    'logs.verboseSub':
        'هر اتصالی که هسته مسیریابی می‌کند ثبت شود، نه فقط هشدارها. مصرف '
            'باتری بیشتر می‌شود و از اتصال بعدی اعمال می‌شود.',
    'logs.lineCount': '{n} خط',
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
