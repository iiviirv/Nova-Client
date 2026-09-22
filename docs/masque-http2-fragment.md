# MASQUE HTTP/2 and TLS fragmentation

## Why this needed a native change

The original Aether v1.9.0 library was pinned at
`311b573352bb67e494895ff67d20b002d075116a` and maps both `h2` and `h3` FFI
transport strings to MASQUE. Its actual HTTP/2 selection and ClientHello
fragmentation originally read CLI environment variables. Nova sent a transport
string but did not configure those variables, and did not send fragmentation
fields. The HTTP/2 and Split TLS choices could therefore still run QUIC.
The engine's fragment defaults already were 16-32 bytes and 2-10 ms.

`tool/core/aether-h2-fragment.patch` makes HTTP/2 and fragmentation explicit
per-job settings, from FFI through scan, verification and tunnel startup.
It does not mutate global environment variables, so searching with different
settings cannot change a running tunnel. CLI paths retain their existing
settings. Native cancellation also drops work that does not explicitly poll
its cancel token, including identity opening.

## User behavior

In Advanced > MASQUE > HTTP/2, enabling Split TLS reveals two fields:

- Fragment size in bytes: one number or an ascending range, default `16-32`.
  Accepted values are 1 through 16384.
- Fragment delay in milliseconds: one number or an ascending range, default
  `2-10`. Accepted values are 0 through 1000.

Invalid entries disable search, manual verification and save. The ranges
survive editing, copying and `aether://` export/import as `fragment_size` and
`fragment_delay`. Native FFI rejects invalid ranges before launching work.

Gateway discovery tries the selected settings first. If a MASQUE search has
not proved a gateway after 90 seconds, it cancels and awaits the old native
work, then tries HTTP/2 with fragmentation. An earlier failed search triggers
that fallback immediately. A successful primary search never switches.
WireGuard, gool and already-fragmented HTTP/2 searches are unchanged.

The fallback uses the configured ranges, shows its phase in English/Persian,
and saves the successful HTTP/2 settings with the endpoint. Addresses rejected
on QUIC are not excluded on TCP. Explicit cancellation does not start fallback;
a stale editor search cannot overwrite a newer search.

## Rebuilding

Run the `Build Aether core` workflow from a Nova ref that includes the patch.
All seven platform/ABI jobs apply the same patch to the pinned upstream tree.
Install their artifacts in the existing native-library locations before
building clients. `aether_version` reports `nova_h2_fragment: 1` for this core.
The iOS app and Network Extension both use the shared Aether.xcframework;
HTTP/2 and fragment settings travel through the existing tunnel JSON envelope.

## Verification

Flutter tests cover range validation, links, CLI/FFI payloads, the 90-second
boundary, awaiting cancellation, early failure, no fallback after success or
user cancellation, preserving successful settings, and narrow English/Persian
layouts with enlarged text.

The native patch includes tests for FFI settings, range rejection and actual
fragment write sizes/delays. `tool/aether_h2_wire_probe.py <library>` additionally
loads the real library and captures TLS ClientHello bytes on loopback for both
verification and tunnel startup, with fragmentation enabled and disabled.
It uses a generated test identity and never registers with WARP. It also
requires cancelled native jobs to finish.

Mutation checks deliberately removed payload values, validation, fallback
cancellation, timing and saved settings. Native checks disabled HTTP/2 and
fragmentation and removed the delay. The wire probe failed when the real TLS
path ignored its fragmentation settings, then passed after restoration.

These checks prove implementation behavior, not reachability from Iran. The
reported Iranian network should still be tested with HTTP/3 blocked, manual
HTTP/2 at 16-32 / 2-10, automatic fallback, and cancellation during each phase.
No claim is made that fragmentation defeats every network restriction.

## Validation on 2026-09-21

- All seven native build jobs passed in workflow run `35633755221`.
  `tool/core/aether-build-manifest.json` records source and library hashes.
- Full Flutter suite: 865 passed, one skipped, three pre-existing
  external-service failures (`nova_panel_test.dart` and
  `subscription_connect_test.dart`). Analyzer reported no issues.
- Eleven Dart mutation cases and four native mutation cases were detected.
  The two locale layout tests also rejected a deliberately lost imported delay.
- Native FFI tests: 18 passed. The loopback wire probe passed against both the
  development library and the CI-built universal macOS release library.
- Android arm64 debug APK compiled. Its Aether executable code and constants
  match the rebuilt library; Android packaging only rewrote the ELF section
  name table.
- iOS release compilation without signing succeeded. The embedded Aether
  framework exactly matches the newly built device slice and exports the
  required entry points. The extension uses the containing app's framework.
- The macOS library contains both CPU architectures with minimum macOS 12.0.
  iOS slices retain BoringSSL isolation.

These are build and implementation checks. No new public client release was
published, and there was no physical Windows/Linux VPN or Iranian-network test.

## Aether 2.0.0 and authorization recovery (QA build 160)

The engine is now pinned to upstream v2.0.0 commit
`0e6f6a5218e65ed4cddc68d1a71d9b9633f89e3f`. Nova's per-job HTTP/2
and fragment patch is rebased onto the new `establish_masque` path. CLI
and nested MASQUE callers retain their environment-derived settings. The
real-library wire probe passes for scan verification and tunnel startup.

Pouyan's build 159 log fails at `await response` with
`TLSV1_ALERT_ACCESS_DENIED` in 609 ms, before the local SOCKS listener or
HTTPS traffic proof. This rules out the 20-second proof deadline for that
attempt, but does not independently establish why the peer rejected it.

After that exact rejection in an HTTP/2 MASQUE gateway check, Nova provisions
a separate identity in private scratch storage and tests the same endpoint.
Only explicit successful WARP proof promotes the candidate. A copy of the
original remains in the private recovery directory. Failed provisioning,
failed proof, cancellation, or a changed original leaves saved credentials
untouched. Ordinary timeouts never trigger recovery. Attempts are limited to
one per search and once per five minutes across searches. No account tokens
or identity contents are added to logs. This is a bounded recovery experiment,
not proof that credentials caused the tester's failure.

The claim that the CLI always refreshes a saved consumer identity was incorrect:
`adopt_team_profile` only refreshes when a Zero Trust team is configured.
Engine version alone is also not established as the cause of this TLS alert.
