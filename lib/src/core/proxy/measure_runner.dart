import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Drives a measuring core's Clash API, one node at a time.
///
/// The old path asked sing-box's `urltest` group to sweep the whole pool and
/// read the group's numbers back. That has three problems this replaces:
///
///  1. **The number was a cold-start number.** sing-box times the dial as well
///     as the request, so a protocol that builds a session or a TLS+HTTP/2
///     connection on its first dial (mieru, NaiveProxy) reported that one-off
///     cost forever: 400-800ms for a server that answers in ~110ms once it is
///     up, measured side by side against `curl` through the same tunnel. Here
///     every node is dialled once to warm it and only the second dial is
///     reported, so the figure is the latency a connected user actually has.
///  2. **The timeout was shared.** The group's budget covered the whole pool,
///     so with a long list the nodes at the end were cut off before their own
///     test had a chance to finish and were reported as "no response". Here the
///     timeout is per node and starts when that node's own test starts, which
///     is what it always claimed to mean.
///  3. **It could not test one node.** Tapping a single row had nothing to call.
///
/// Everything here is plain HTTP against `127.0.0.1`, so the same code runs on
/// Android, iOS, Windows and macOS against whichever measuring core that
/// platform starts.
class MeasureRunner {
  const MeasureRunner._();

  /// How many nodes are tested at once. sing-box's own sweep used ten; eight
  /// leaves a little headroom on a phone, where each dial's handshake is real
  /// CPU work and contention is what inflated the cold numbers in the first
  /// place.
  static const int kDefaultConcurrency = 8;

  /// The Clash API parses `timeout` into an **int16**, so anything above 32767
  /// is answered with 400 Bad Request and the node reads "no response" no
  /// matter how healthy it is. A user who sets a 60s timeout must not silently
  /// break every test, so the wire value is clamped well inside the limit.
  static const int kMaxTimeoutMs = 30000;

  /// The test URL as the Clash API needs it spelled.
  ///
  /// sing-box's `/proxies/{tag}/delay` handler throws away any URL starting
  /// with the literal `http://` and substitutes its own
  /// `https://www.gstatic.com/generate_204`. That silently added a second TLS
  /// handshake (one more round trip through the proxy) to every measurement:
  /// on a real subscription it roughly doubled every number, 251 -> 134ms on a
  /// clean IP, 485 -> 218ms on mieru. The check is case-sensitive and
  /// `Uri.parse` lowercases the scheme, so spelling the scheme in capitals
  /// gets the plain-HTTP request we asked for and the handler leaves it alone.
  static String wireUrl(String url) {
    final String u = url.trim();
    if (u.isEmpty) return 'HTTP://www.gstatic.com/generate_204';
    if (u.startsWith('http://')) return 'HTTP://${u.substring(7)}';
    return u;
  }

  /// Waits for a freshly started measuring core to answer on its Clash API.
  static Future<bool> waitForApi(
    Uri api, {
    Duration timeout = const Duration(seconds: 15),
    http.Client? client,
    bool Function()? cancelled,
  }) async {
    final http.Client c = client ?? http.Client();
    final Uri version = api.resolve('version');
    final Stopwatch clock = Stopwatch()..start();
    try {
      while (clock.elapsed < timeout) {
        if (cancelled?.call() ?? false) return false;
        try {
          final http.Response r =
              await c.get(version).timeout(const Duration(milliseconds: 700));
          if (r.statusCode == 200) return true;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      if (client == null) c.close();
    }
    return false;
  }

  /// Tests one node and returns its round trip in ms, or null if it did not
  /// answer inside [timeoutSec].
  static Future<int?> probe(
    Uri api,
    String tag, {
    required String url,
    required int timeoutSec,
    http.Client? client,
    void Function(String reason)? onFailure,
  }) async {
    final http.Client c = client ?? http.Client();
    final int ms = (timeoutSec.clamp(1, 60) * 1000).clamp(1000, kMaxTimeoutMs);
    final Uri u = api.resolve('proxies/${Uri.encodeComponent(tag)}/delay').replace(
        queryParameters: <String, String>{
          'url': wireUrl(url),
          'timeout': '$ms',
        });
    try {
      final http.Response r =
          await c.get(u).timeout(Duration(milliseconds: ms + 3000));
      if (r.statusCode != 200) {
        onFailure?.call('$tag: HTTP ${r.statusCode} ${r.body.trim()}');
        return null;
      }
      final Object? body = jsonDecode(r.body);
      final Object? delay = body is Map ? body['delay'] : null;
      if (delay is num && delay > 0) return delay.toInt();
      onFailure?.call('$tag: no delay in ${r.body.trim()}');
      return null;
    } catch (e) {
      onFailure?.call('$tag: $e');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Measures every node in [tagKeys] (tag -> stable node key) and returns the
  /// node keys that answered, with their latency.
  ///
  /// [onProgress] is called as rows land, with the delays so far and the set of
  /// node keys that already carry a verdict, so the list fills in live rather
  /// than all at once at the end.
  static Future<Map<String, int>> run({
    required Uri api,
    required Map<String, String> tagKeys,
    required String url,
    required int timeoutSec,
    int concurrency = kDefaultConcurrency,
    void Function(Map<String, int> delays, Set<String> tested)? onProgress,
    bool Function()? cancelled,
    http.Client? client,
    // The first few reasons servers gave for not answering. A run that returns
    // nothing at all is almost never "every server is down"; it is usually one
    // cause affecting all of them, and without this the log could only say
    // "0 answered". That is how a missing resolver went unnoticed.
    List<String>? failures,
    /// Stop once this many servers have answered. The free list uses it: its
    /// pool is deliberately larger than anyone needs, so testing all of it
    /// spends minutes producing a list nobody scrolls through. Servers already
    /// dialled keep their verdicts; the rest are simply not started.
    int? stopAfterWorking,
  }) async {
    final http.Client c = client ?? http.Client();
    final Map<String, int> delays = <String, int>{};
    final Set<String> tested = <String>{};
    final List<String> queue = tagKeys.keys.toList();
    int next = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelled?.call() ?? false) return;
        if (stopAfterWorking != null && delays.length >= stopAfterWorking) return;
        final int i = next++;
        if (i >= queue.length) return;
        final String tag = queue[i];
        final String? key = tagKeys[tag];
        if (key == null) continue;
        // First dial: builds whatever the protocol needs to build (a mieru
        // session, a NaiveProxy TLS + HTTP/2 connection, a TLS session ticket).
        // Its number is thrown away; it is the setup cost, not the latency.
        int? warm = await probe(api, tag,
            url: url,
            timeoutSec: timeoutSec,
            client: c,
            onFailure: (String why) {
              if (failures != null && failures.length < 3) failures.add(why);
            });
        if (warm == null && !(cancelled?.call() ?? false)) {
          // One retry before a server is written off. Measured against Nova's
          // own free list, where the servers are busy and often answer late:
          // four of eighteen failed their first dial and answered the second in
          // 229 to 1516ms. Calling those dead would have hidden working servers
          // from the people who have nothing else. Only a node that is already
          // failing pays for this.
          warm = await probe(api, tag,
              url: url, timeoutSec: timeoutSec, client: c);
        }
        int? best = warm;
        if (warm != null) {
          if (cancelled?.call() ?? false) return;
          // Second dial, on everything the first one warmed up. This is the
          // number the user sees, and the one that matches what they measure
          // from inside the tunnel.
          final int? hot = await probe(api, tag,
              url: url, timeoutSec: timeoutSec, client: c);
          if (hot != null && hot < best!) best = hot;
        }
        tested.add(key);
        if (best != null) delays[key] = best;
        onProgress?.call(Map<String, int>.from(delays), Set<String>.from(tested));
      }
    }

    // A second pass over only the servers that said nothing.
    //
    // Running the whole test again is what users were doing by hand, and it
    // works: measured over the same 200-server pool three times, the second run
    // found 6 servers the first had written off and the third found 3 more, so
    // a single pass under-reports a list by a few percent even on a good
    // connection. On a bad one, where the first pass is fighting for every
    // socket at once, the gap is much wider.
    //
    // Doing it here instead means the retry happens when the pool is no longer
    // saturated and the core's resolver is warm, which is exactly the condition
    // that made the manual re-run succeed. Only failures pay for it, and a
    // server that answers now is a server the user can actually use.
    Future<void> retryFailures() async {
      final List<String> again = <String>[
        for (final MapEntry<String, String> e in tagKeys.entries)
          if (!delays.containsKey(e.value)) e.key,
      ];
      // No late retry when the run stopped early on purpose: the servers that
      // said nothing were never the reason it ended, and the user is waiting on
      // a list that is already long enough.
      if (again.isEmpty) return;
      if (stopAfterWorking != null && delays.length >= stopAfterWorking) return;
      int at = 0;
      Future<void> retryWorker() async {
        while (true) {
          if (cancelled?.call() ?? false) return;
          final int i = at++;
          if (i >= again.length) return;
          final String tag = again[i];
          final String? key = tagKeys[tag];
          if (key == null) continue;
          final int? ms = await probe(api, tag,
              url: url, timeoutSec: timeoutSec, client: c);
          if (ms != null) {
            delays[key] = ms;
            onProgress?.call(
                Map<String, int>.from(delays), Set<String>.from(tested));
          }
        }
      }

      await Future.wait(<Future<void>>[
        for (int i = 0; i < concurrency.clamp(1, 32); i++) retryWorker(),
      ]);
    }

    try {
      await Future.wait(<Future<void>>[
        for (int i = 0; i < concurrency.clamp(1, 32); i++) worker(),
      ]);
      if (!(cancelled?.call() ?? false)) await retryFailures();
    } finally {
      if (client == null) c.close();
    }
    return delays;
  }

  /// The wall-clock a run can take at worst: every node timing out twice would
  /// be the true ceiling, but a node that fails its warm-up dial is never
  /// dialled again, so one timeout per node per batch is the real bound. Used
  /// only as a safety net; the run normally ends when the last node answers.
  @visibleForTesting
  static Duration budgetFor(int nodes, int timeoutSec, {int concurrency = kDefaultConcurrency}) {
    final int batches = (nodes / concurrency.clamp(1, 32)).ceil().clamp(1, 1000);
    return Duration(seconds: batches * (timeoutSec.clamp(1, 60) * 2 + 1) + 10);
  }
}
