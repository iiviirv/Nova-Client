import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The GitHub release tag this build shipped as. The daily update check compares
/// it to the latest release; if they differ, an update is offered. Bump this in
/// step with the build number every release (see settings_screen's kNovaBuild).
const String kNovaReleaseTag = 'v1.20.9-beta';

/// The marketing version and build number this build shipped as, shown in
/// Settings' About footer. They mirror pubspec.yaml's `version:` (a test pins
/// them to it, because they sat at 0.3.3 (82) through five releases).
const String kNovaVersion = '0.9.9';
const String kNovaBuild = '109';

/// The public repo whose releases the app updates from.
const String kNovaRepo = 'IRNova/Nova-Client';

/// Where a user goes to download a newer build.
const String kNovaReleasesUrl = 'https://github.com/$kNovaRepo/releases/latest';

/// Set to the latest release tag when it is newer than what this build shipped
/// as ([kNovaReleaseTag]), else null. The dashboard shows a small banner while
/// it is non-null; tapping it opens [kNovaReleasesUrl]. Kept as a plain global
/// notifier so the check needs no controller wiring.
final ValueNotifier<String?> novaUpdateTag = ValueNotifier<String?>(null);

/// How long between automatic checks. Three hours, not a day: during a beta
/// the releases come faster than that, and a user who launched right after
/// installing recorded their one daily check and then heard nothing about the
/// next two releases (reported from the field on 2026-08-19). One tiny API
/// call per three hours of use is not a cost worth saving.
const int kUpdateCheckGateMs = 3 * 60 * 60 * 1000;

const String _kLastCheckKey = 'nova.update.lastCheckMs';
const String _kLatestTagKey = 'nova.update.latestTag';

/// Checks GitHub for a newer release, at most once a day, and updates
/// [novaUpdateTag]. Best-effort: any failure (the API being blocked, offline,
/// a rate limit) leaves the last known state untouched and never surfaces an
/// error. Pass [force] to bypass the once-a-day gate (the manual "check now").
Future<void> checkForNovaUpdate(
  SharedPreferences prefs, {
  bool force = false,
  int nowMs = 0,
  Future<String> Function(Uri)? fetch,
}) async {
  // Never on iOS. The banner's whole job is to send someone to the GitHub
  // releases page, and an iPhone cannot install from it: there, a new build
  // arrives through the App Store or TestFlight or not at all. Showing it would
  // point users (and an App Store reviewer) at a download outside the store,
  // which is both useless to them and a bad look on the review.
  if (Platform.isIOS) return;
  // Restore the last verdict so a banner survives an app restart within the day.
  final String? remembered = prefs.getString(_kLatestTagKey);
  if (remembered != null && _isNewer(remembered)) {
    novaUpdateTag.value = remembered;
  }

  final int now = nowMs;
  final int last = prefs.getInt(_kLastCheckKey) ?? 0;
  // now == 0 means "caller did not pass a clock" (startup path); only the gate
  // needs it, so a forced check still runs.
  if (!force && now > 0 && last > 0 && now - last < kUpdateCheckGateMs) return;

  try {
    final Uri api =
        Uri.parse('https://api.github.com/repos/$kNovaRepo/releases/latest');
    final String body = await (fetch ?? _get)(api);
    final Object? json = jsonDecode(body);
    if (json is! Map) return;
    final Object? tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return;

    if (now > 0) await prefs.setInt(_kLastCheckKey, now);
    await prefs.setString(_kLatestTagKey, tag);
    novaUpdateTag.value = _isNewer(tag) ? tag : null;
  } catch (_) {
    // Blocked, offline, or malformed: keep whatever we last knew.
  }
}

/// A release tag counts as newer only when its version number is higher than
/// the one this build shipped as. "Different" was the old test, and it misfired
/// the day after every release: the tag remembered from yesterday's check
/// (v1.12.0-beta) differed from the freshly installed v1.13.0-beta, so the
/// just-updated app kept offering "1.12 is available".
bool _isNewer(String latestTag) =>
    compareReleaseTags(latestTag, kNovaReleaseTag) > 0;

/// Compares two `vMAJOR.MINOR.PATCH[-suffix]` tags numerically. Positive when
/// [a] is newer than [b]. A tag that does not parse is never newer.
@visibleForTesting
int compareReleaseTags(String a, String b) {
  final List<int>? pa = _numbers(a);
  final List<int>? pb = _numbers(b);
  if (pa == null || pb == null) return 0;
  for (int i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] > pb[i] ? 1 : -1;
  }
  return 0;
}

List<int>? _numbers(String tag) {
  final RegExpMatch? m =
      RegExp(r'^v?(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(tag.trim());
  if (m == null) return null;
  return <int>[
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3) ?? '0'),
  ];
}

Future<String> _get(Uri url) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  try {
    final HttpClientRequest req = await client.getUrl(url);
    // GitHub requires a User-Agent and rewards the versioned Accept header.
    req.headers.set(HttpHeaders.userAgentHeader, 'NovaClient');
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final HttpClientResponse resp =
        await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub HTTP ${resp.statusCode}');
    }
    return await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 10));
  } finally {
    client.close(force: true);
  }
}

/// What a manual "check for updates" found.
enum NovaUpdateCheck { updateAvailable, upToDate, failed }

/// Runs a forced check and says what happened, so the Settings row can answer
/// the user instead of silently opening a web page.
Future<NovaUpdateCheck> checkForNovaUpdateNow(
  SharedPreferences prefs, {
  int nowMs = 0,
  Future<String> Function(Uri)? fetch,
}) async {
  final String? before = prefs.getString(_kLatestTagKey);
  await checkForNovaUpdate(prefs,
      force: true,
      nowMs: nowMs == 0 ? DateTime.now().millisecondsSinceEpoch : nowMs,
      fetch: fetch);
  final String? after = prefs.getString(_kLatestTagKey);
  if (after == null) return before == null ? NovaUpdateCheck.failed : NovaUpdateCheck.upToDate;
  return _isNewer(after) ? NovaUpdateCheck.updateAvailable : NovaUpdateCheck.upToDate;
}
