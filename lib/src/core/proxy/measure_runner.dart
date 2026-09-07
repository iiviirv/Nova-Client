import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../logging/nova_log.dart';

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

  /// Where an endpoint node is measured to.
  ///
  /// An IP literal on purpose. Measuring through an endpoint's own inbound
  /// showed the core failing DNS on that path ("cannot marshal DNS message"),
  /// so a hostname target cannot be resolved there however healthy the tunnel
  /// is. Against a live AmneziaWG server this address answered in 245ms while
  /// a hostname timed out, and the redirect it returns is fine: what is being
  /// timed is the round trip, not the body.
  static const String kEndpointProbeUrl = 'http://1.1.1.1/';

  /// Tests one endpoint node (AmneziaWG / WireGuard) by timing a request
  /// through the local inbound that [SingboxConfig.buildMeasureMap] pinned to
  /// it, rather than asking the Clash API.
  ///
  /// The Clash API lists endpoints but cannot dial one: a delay request against
  /// an AmneziaWG tag fails immediately without the core so much as attempting
  /// a connection. Every such server therefore read "no response" while
  /// connecting to it worked perfectly.
  static Future<int?> probeEndpoint(
    int port, {
    required int timeoutSec,
    String url = kEndpointProbeUrl,
    void Function(String reason)? onFailure,
  }) async {
    final Duration budget = Duration(seconds: timeoutSec.clamp(1, 60));
    // Not a cascade: an arrow closure swallows the following `..`, so the rest
    // would be set on the String it returns.
    final HttpClient c = HttpClient();
    c.findProxy = (Uri _) => 'PROXY 127.0.0.1:$port';
    c.connectionTimeout = budget;
    c.idleTimeout = const Duration(seconds: 1);
    c.autoUncompress = false;
    final Stopwatch clock = Stopwatch()..start();
    try {
      final HttpClientRequest req =
          await c.getUrl(Uri.parse(url)).timeout(budget);
      req.followRedirects = false;
      final HttpClientResponse res = await req.close().timeout(budget);
      clock.stop();
      unawaited(res.drain<void>().catchError((Object _) {}));
      return clock.elapsedMilliseconds;
    } catch (e) {
      onFailure?.call('endpoint on :$port: $e');
      return null;
    } finally {
      c.close(force: true);
    }
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

  /// The tags a plain TCP connect could not reach.
  ///
  /// A filtered address is the case this exists for. It cannot complete a TCP
  /// handshake, yet without this it still spends a first dial, a retry of that
  /// first dial, and a place in the late retry pass proving it: about thirty
  /// seconds and one of only [kDefaultConcurrency] slots, per dead server, to
  /// learn what one refused SYN says in under a second.
  ///
  /// **Only failure is trusted.** A server that accepts TCP has proved nothing
  /// about whether the proxy on top of it works, so it is not in the returned
  /// set and goes on to the real dial exactly as before. This is a fast way to
  /// be certain something is dead, never a way to decide it is alive.
  ///
  /// Callers must pass only protocols where TCP silence means dead: see
  /// [NodeProtocolName.tcpLivenessMeaningful], which excludes UDP-native
  /// protocols and mieru.
  @visibleForTesting
  static Future<Set<String>> unreachableTags(
    Map<String, ({String host, int port})> probes, {
    Duration timeout = const Duration(milliseconds: 1200),
    int concurrency = kDefaultConcurrency,
    bool Function()? cancelled,
  }) async {
    if (probes.isEmpty) return <String>{};
    final Set<String> dead = <String>{};
    final List<String> tags = probes.keys.toList();
    int at = 0;
    Future<void> worker() async {
      while (true) {
        if (cancelled?.call() ?? false) return;
        final int i = at++;
        if (i >= tags.length) return;
        final String tag = tags[i];
        final ({String host, int port})? a = probes[tag];
        if (a == null) continue;
        Socket? sock;
        try {
          sock = await Socket.connect(a.host, a.port, timeout: timeout);
        } catch (_) {
          dead.add(tag);
        } finally {
          try {
            sock?.destroy();
          } catch (_) {}
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < concurrency.clamp(1, 32) * 2; i++) worker(),
    ]);
    return dead;
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
    /// Node tag to the local port pinned to it, for endpoint nodes that the
    /// Clash API cannot dial. Empty for a pool with no WireGuard/AmneziaWG.
    Map<String, int> endpointPorts = const <String, int>{},
    /// Tag -> the address a plain TCP connect can reach the server on, for the
    /// protocols where TCP silence means the node is dead (see
    /// [NodeProtocolName.tcpLivenessMeaningful]). Empty disables the pre-pass.
    Map<String, ({String host, int port})> tcpProbes =
        const <String, ({String host, int port})>{},
    /// Tags that need the long first dial. When this is empty every tag gets
    /// it, which is the old behaviour.
    Set<String> slowFirstDial = const <String>{},
    /// How long the reachability pre-pass waits for a TCP handshake. Short on
    /// purpose: this is not measuring quality, only asking whether anything is
    /// there at all.
    Duration reachTimeout = const Duration(milliseconds: 1200),
    int concurrency = kDefaultConcurrency,
    /// The budget for the first (cold) dial, which is a different question from
    /// the budget for the number the user sees.
    ///
    /// Everything that failed here failed the same way: Reality, Hysteria2,
    /// SS2022 and mieru all dial a bare VPS and all pay a real handshake to open
    /// the session (QUIC + congestion setup, a TLS handshake against the
    /// borrowed SNI, a mieru session), while the ones that always passed
    /// (VLESS-ws, xhttp, NaiveProxy) ride a CDN edge and are up in a couple of
    /// hundred milliseconds. On the default five seconds, shared with seven
    /// other cold dials, the cheap ones finished and the expensive ones were
    /// called dead - and the retry ran while the pool was still saturated, which
    /// is why the same server answered on one run and not the next.
    ///
    /// Only the warm-up gets this. The reported figure still comes from the hot
    /// dial on the normal timeout, so no number moves because of it.
    int? warmTimeoutSec,
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
    /// Ends the run as soon as this accepts the delays found so far. Richer
    /// than [stopAfterWorking], which can only count: the free list needs "the
    /// list is long enough AND enough of it is fast enough".
    bool Function(Map<String, int> delays)? stopWhen,
  }) async {
    final http.Client c = client ?? http.Client();
    final int warmSec = (warmTimeoutSec ?? timeoutSec * 3).clamp(timeoutSec, 60);
    final Map<String, int> delays = <String, int>{};
    final Set<String> tested = <String>{};
    final List<String> queue = tagKeys.keys.toList();
    int next = 0;

    /// The first dial's budget for one node.
    ///
    /// The long budget exists for servers that set up a session before they can
    /// answer, and giving it to the rest is most of the wait on a list with
    /// dead entries: a CDN-fronted server answers in a couple of hundred
    /// milliseconds or not at all, so seconds two through fifteen buy nothing.
    /// An empty [slowFirstDial] means nobody was classified, so everyone keeps
    /// the old budget rather than being quietly sped up on a guess.
    int firstDialSecFor(String tag) {
      if (slowFirstDial.isEmpty) return warmSec;
      return slowFirstDial.contains(tag) ? warmSec : timeoutSec;
    }

    // Run it before anything expensive, and fold the verdicts in as final: a
    // node that could not be reached at all is reported as tested with no
    // delay, which is what the old path would have concluded far more slowly.
    Set<String> unreachable = await unreachableTags(
      tcpProbes,
      timeout: reachTimeout,
      concurrency: concurrency,
      cancelled: cancelled,
    );
    // Ask the failures a second time before believing them.
    //
    // A lost SYN is not a dead server. Linux and Android retransmit the first
    // SYN after about a second, so on a lossy international path out of Iran,
    // one dropped packet pushes the handshake past the budget and a working
    // server is deleted from the run: it is skipped here AND excluded from the
    // late retry pass, where before this change it had three chances. At even
    // ten percent loss that quietly removes about a tenth of a user's live
    // servers, and the all-failed guard below never fires because most of them
    // succeeded.
    //
    // Only the nodes already believed dead pay for this, so it costs one more
    // short round and keeps essentially all of the speedup.
    if (unreachable.isNotEmpty && !(cancelled?.call() ?? false)) {
      unreachable = await unreachableTags(
        <String, ({String host, int port})>{
          for (final String t in unreachable)
            if (tcpProbes[t] != null) t: tcpProbes[t]!,
        },
        timeout: reachTimeout,
        concurrency: concurrency,
        cancelled: cancelled,
      );
    }
    // If NOTHING could be reached, distrust the probe rather than the servers.
    //
    // The probe runs from the app, and the dial runs from the core. Those are
    // normally the same path, but they are not guaranteed to be: another VPN, a
    // captive portal, a per-app rule, or simply no network at all makes every
    // TCP connect fail while the core can still dial. Writing the whole list
    // off in that case would hide working servers from someone who may have
    // nothing else, which is the one outcome worth being slow to avoid.
    //
    // A partial result is the trustworthy one: if some servers answered TCP and
    // others refused, the refusals are about those servers.
    if (tcpProbes.isNotEmpty && unreachable.length == tcpProbes.length) {
      NovaLog.instance.write(
          'Every server refused a TCP connection, so the quick check is being '
          'ignored and all of them will be dialled',
          level: NovaLogLevel.warn);
      unreachable = <String>{};
    }
    if (unreachable.isNotEmpty) {
      for (final String tag in unreachable) {
        final String? key = tagKeys[tag];
        if (key != null) tested.add(key);
      }
      queue.removeWhere(unreachable.contains);
      NovaLog.instance.write(
          'Skipped ${unreachable.length} servers that refused a TCP connection');
      onProgress?.call(
          Map<String, int>.from(delays), Set<String>.from(tested));
    }

    /// One measurement of one node, by whichever route can actually reach it.
    ///
    /// Endpoint nodes (AmneziaWG / WireGuard) go through the local inbound that
    /// [SingboxConfig.buildMeasureMap] pinned to them; everything else goes
    /// through the Clash API as before.
    Future<int?> dial(String tag,
        {required int seconds, void Function(String reason)? onFailure}) {
      final int? port = endpointPorts[tag];
      if (port != null) {
        return probeEndpoint(port, timeoutSec: seconds, onFailure: onFailure);
      }
      return probe(api, tag,
          url: url, timeoutSec: seconds, client: c, onFailure: onFailure);
    }

    Future<void> worker() async {
      while (true) {
        if (cancelled?.call() ?? false) return;
        if (stopAfterWorking != null && delays.length >= stopAfterWorking) return;
        if (stopWhen != null && stopWhen(delays)) return;
        final int i = next++;
        if (i >= queue.length) return;
        final String tag = queue[i];
        final String? key = tagKeys[tag];
        if (key == null) continue;
        // First dial: builds whatever the protocol needs to build (a mieru
        // session, a NaiveProxy TLS + HTTP/2 connection, a TLS session ticket).
        // Its number is thrown away; it is the setup cost, not the latency.
        final int firstSec = firstDialSecFor(tag);
        int? warm = await dial(tag, seconds: firstSec,
            onFailure: (String why) {
          if (failures != null && failures.length < 12) failures.add(why);
        });
        if (warm == null && !(cancelled?.call() ?? false)) {
          // One retry before a server is written off. Measured against Nova's
          // own free list, where the servers are busy and often answer late:
          // four of eighteen failed their first dial and answered the second in
          // 229 to 1516ms. Calling those dead would have hidden working servers
          // from the people who have nothing else. Only a node that is already
          // failing pays for this.
          warm = await dial(tag, seconds: firstSec);
        }
        int? best = warm;
        if (warm != null) {
          if (cancelled?.call() ?? false) return;
          // Second dial, on everything the first one warmed up. This is the
          // number the user sees, and the one that matches what they measure
          // from inside the tunnel.
          final int? hot = await dial(tag, seconds: timeoutSec);
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
          // A server that refused a TCP connection is not a server that
          // answered late, so it does not get a second pass either. Retrying it
          // would put the whole cost back that the pre-pass just removed.
          if (!delays.containsKey(e.value) && !unreachable.contains(e.key))
            e.key,
      ];
      // No late retry when the run stopped early on purpose: the servers that
      // said nothing were never the reason it ended, and the user is waiting on
      // a list that is already long enough.
      if (again.isEmpty) return;
      if (stopAfterWorking != null && delays.length >= stopAfterWorking) return;
      if (stopWhen != null && stopWhen(delays)) return;
      int at = 0;
      Future<void> retryWorker() async {
        while (true) {
          if (cancelled?.call() ?? false) return;
          final int i = at++;
          if (i >= again.length) return;
          final String tag = again[i];
          final String? key = tagKeys[tag];
          if (key == null) continue;
          final int? ms = await dial(tag, seconds: firstDialSecFor(tag),
              onFailure: (String why) {
            if (failures != null && failures.length < 12) failures.add(why);
          });
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
