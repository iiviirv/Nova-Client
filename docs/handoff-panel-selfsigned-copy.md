# Handoff (Nova Server / panel): the self-signed certificate copy overclaims

**For:** whoever works on the Nova Server panel.
**From:** the Nova-Client side, from a tester's report on a clean install.

## What was reported

A new VPS, clean Nova Server install. During install it said a certificate had
been issued for the IP. Opening the panel, no browser would load it over https:
Chrome shows **Not secure** with `https` struck through in the address bar.

Meanwhile the panel's Network > Domains page says, on the same node:

> This node uses a self-signed certificate on 134.122.61.28.
> **The certificate for 134.122.61.28 is valid and apps will accept it.**

## Why it happens

Both things are true at once, and the copy only tells the user one of them.

A self-signed certificate is exactly that: signed by the node, trusted by
nothing. No browser will ever accept it without the user clicking through an
interstitial, and no amount of reinstalling changes that. The install did not
fail; the sentence describing what it produced is wrong.

"Apps will accept it" is also only partly true, and the exception is one Nova
has already been bitten by:

- **Nova-Client** accepts it (it fetches a bare-IP subscription with
  allow-insecure on purpose, see the client's self-signed fix).
- **Third-party Xray clients do not.** xray-core made `allowInsecure` a hard
  error, so a no-domain link from this node fails on them outright (see
  [`xray-deprecations`](https://github.com/IRNova/Nova-Server) notes on the
  server side).

So a user reading that line is told the browser problem does not exist and told
that every app is fine, and neither holds.

## Suggested copy

Replace the green "valid" line with something that describes the two audiences
separately. English, and the Farsi should follow the same split:

> **This node uses a self-signed certificate on 134.122.61.28.**
> Your browser will warn you the first time and you can continue past it. Nova
> Client accepts this certificate, but some other apps refuse self-signed
> certificates entirely.
> **Add a domain to get a certificate browsers and every app trust.** It is
> free and takes a minute (Let's Encrypt, or Cloudflare below).

Points that matter in the wording:

1. Say the browser warning is **expected**, before the user goes looking for a
   bug that is not there.
2. Do not promise every app. Name Nova Client, and warn that others may refuse.
3. End on the fix, since adding a domain is the thing that makes all of it go
   away and the panel already has both paths on that same page.

The check itself does not need to change. Only the sentence.
