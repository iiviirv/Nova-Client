# Psiphon fork review

Reviewed 2026-09-23, before any Psiphon code was written, because the two things
that could rule this out are whether the fork can be trusted and what it costs.

## Subject

`CluvexStudio/psiphon-tunnel-core`, branch `shirokhorshid`, pinned at
`83aa73b9b982e7421e00117f5b0c5aceb5dda452`. A real fork of
`Psiphon-Labs/psiphon-tunnel-core` (GPL-3.0): 271 unique commits and 8889 added
lines across 49 files outside `vendor/`. The additions are a CDN fronting scan,
SOCKS UDP associate, local proxy authentication and fronted meek CDN variants.

## Findings

**Certificate verification, the one real change.** The fork generalises
Psiphon's single `VerifyServerName` into a list and adds
`verifyServerCertificateAny`, which accepts a certificate that verifies against
any name in that list. Followed to the end:

- the chain is still verified to a trusted root by upstream's own
  `common.VerifyServerCertificate`; no step is skipped
- candidate names come from `makeFrontedMeekCDNScanVerifyServerNames` (the
  built-in scan list) and `meekConfig.VerifyServerNames` (authenticated server
  entries), never from anything a network attacker supplies
- `InsecureSkipVerify` is set only where upstream already set it, in the
  domain-fronting case where SNI deliberately differs from the verified host

Acceptable, and correct for scanning several CDN fronts. It is the single place
verification was loosened and the first place to re-read if this is revisited.

**No new phone-home.** Every added `https://` string is a documentation
reference or a provenance comment in `frontedMeekCDNScanBuiltIn.go` recording
where the baked-in CDN ranges came from. None are fetched at runtime.

**Built-in CDN list**: about 1159 ordinary CDN hostnames (Akamai, Fastly, AWS,
GitHub) plus Iranian hosts such as aparat.com. Nothing unfamiliar.

**Local proxy authentication is fail-closed.** `localProxyAuthRequiredForClient`
requires credentials for every non-loopback client and exempts loopback, and an
unparseable remote address falls through to requiring auth rather than skipping
it. The same shape Nova already uses for LAN sharing.

**No weak crypto, no `exec`, no `unsafe`, no plaintext endpoints** among the
added lines.

## One thing Nova must handle

`psiphon/tunnel.go` writes a peer address into the notice stream:

    NoticeWarning("rejecting in-proxy from country %s (IP: %s)", country, proxyIP)

That is another party's address rather than the user's, but Nova invites people
to paste its log in public, and v1.24.2 shipped with the user's own address in
that log. **Psiphon notices must not reach the shareable app log unscrubbed.**

## Not covered

Reviewed: the TLS and verification delta, local proxy auth, CDN scan endpoints
and built-in list, notice handling, and a red-flag scan across all 8889 added
lines. Not reviewed line by line: `psiphon/udpgw.go` (489 new lines of UDP
relay), the inproxy and WebRTC changes, and the datastore and parameters
changes. Those are the next places to look if this goes past Phase 1.

## Decision

Build the fork, not upstream: the CDN fronting scan is the part that addresses
Nova's actual problem, finding a path when known endpoints are blocked.

Mitigate the provenance risk rather than the code: pin the reviewed commit, fail
the build when the pin does not match, and never fall back to a branch.
`tool/build_psiphon.sh` does this. Aether's own `psiphon-build.sh` falls back to
"the branch as it stands" when the pinned commit is gone, which would silently
build unreviewed code into a censorship tool; Nova does not copy that.

Mirroring the pinned commit into an account we control removes the last way the
pin can disappear. `PSIPHON_REPO` exists for exactly that.
