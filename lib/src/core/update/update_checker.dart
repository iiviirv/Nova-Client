import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The GitHub release tag this build shipped as. The daily update check compares
/// it to the latest release; if they differ, an update is offered. Bump this in
/// step with the build number every release (see settings_screen's kNovaBuild).
const String kNovaReleaseTag = 'v1.11.0-beta';

/// The public repo whose releases the app updates from.
const String kNovaRepo = 'IRNova/Nova-Client';

/// Where a user goes to download a newer build.
const String kNovaReleasesUrl = 'https://github.com/$kNovaRepo/releases/latest';

/// Set to the latest release tag when it is newer than what this build shipped
/// as ([kNovaReleaseTag]), else null. The dashboard shows a small banner while
/// it is non-null; tapping it opens [kNovaReleasesUrl]. Kept as a plain global
/// notifier so the check needs no controller wiring.
final ValueNotifier<String?> novaUpdateTag = ValueNotifier<String?>(null);

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
  // Restore the last verdict so a banner survives an app restart within the day.
  final String? remembered = prefs.getString(_kLatestTagKey);
  if (remembered != null && _isNewer(remembered)) {
    novaUpdateTag.value = remembered;
  }

  final int now = nowMs;
  final int last = prefs.getInt(_kLastCheckKey) ?? 0;
  const int dayMs = 24 * 60 * 60 * 1000;
  // now == 0 means "caller did not pass a clock" (startup path); only the gate
  // needs it, so a forced check still runs.
  if (!force && now > 0 && last > 0 && now - last < dayMs) return;

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

/// A release tag counts as newer when it simply differs from the one this build
/// shipped as. Releases only ever move forward and the latest endpoint is always
/// the newest non-prerelease, so "different" is a safe, simple proxy for "newer"
/// without a full semver parse of the `-beta` tags.
bool _isNewer(String latestTag) =>
    latestTag.trim().isNotEmpty && latestTag.trim() != kNovaReleaseTag.trim();

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
