# App Store 4.3(a) repositioning package

The rejection is **Guideline 4.3(a) - Design - Spam**: Apple's engine matched Nova's
*binary, metadata, and concept* to (1) other developers' proxy clients and (2) an
app from a **terminated** developer account. Features do not answer 4.3 — Apple
already saw Radar / Deploy and held firm. The only levers are **concept, metadata,
identity, and account**. This package is the concept + metadata rewrite; the
account/identity moves are listed at the end.

Guiding principle: **stop shipping "a proxy client."** Ship a **self-hosting +
network-diagnostics toolkit for your own Cloudflare edge** that happens to include
connectivity. Everything below leads with Radar, Deploy, and the toolkit; the VPN
is the *last* thing mentioned, framed as "bring your own config," never a service.

---

## 1. Name (drop "Proxy" entirely)

"Nova **Proxy**" signals the exact concept Apple flagged. Options, best first:

| Name | Why |
|---|---|
| **Nova Edge** | "Edge" = Cloudflare edge / self-host; reads as a deploy+ops tool, not a VPN. |
| **Nova Edge Kit** | Even clearer it's a toolkit. |
| **NovaDeploy** | Leads with the unique deploy-your-own-Worker feature. |
| **Nova Net Tools** | Diagnostics-first framing (Radar, IP toolkit). |

Recommendation: **Nova Edge** (subtitle carries the specifics). Whatever you pick,
it must not contain "Proxy", "VPN", or "Tunnel".

## 2. Subtitle (max 30 chars)

Pick one:
- `Deploy & scan your own edge`
- `Self-host + clean-IP radar`
- `Your Cloudflare edge toolkit`

## 3. Keywords (100 chars, comma-separated, no spaces after commas)

`cloudflare,worker,deploy,edge,network,diagnostics,ip scanner,latency,self-host,developer,dns,toolkit`

Deliberately **omits** "vpn, proxy, tunnel, unblock, filter" — those keywords are
what cluster you with the duplicate apps.

## 4. Promotional text (max 170 chars)

`Deploy your own Cloudflare Worker from your phone, scan for the fastest clean edge IPs, and diagnose your network - your infrastructure, your keys, your rules.`

## 5. Description (lead with the differentiators; connectivity last)

```
Nova Edge is a toolkit for people who run their own Cloudflare edge. Deploy, scan,
diagnose, and connect to infrastructure YOU control - no bundled service, no
accounts to buy, nothing shared with anyone else.

DEPLOY YOUR OWN
- Sign in to your own Cloudflare account and deploy a Worker in a couple of taps.
- The app builds the Worker, KV, and D1 for you; you hold the keys the whole time.
- Manage, update, and remove your Workers from your phone.

NOVA RADAR - CLEAN-IP SCANNER
- On-device scanner that pulls candidate Cloudflare IP ranges, tests each over TCP
  and TLS, ranks them by real latency, and applies the fastest one in one tap.
- See exactly which edge IPs are reachable and how fast, live.

NETWORK TOOLKIT
- Build and inspect connection configs, resolve over DoH, check reachability, and
  read a full core log of what your device is actually doing.
- Per-network tuning (fingerprint, fragmentation) you control.

CONNECT TO YOUR OWN CONFIG
- Bring your own configuration and connect through infrastructure you deployed.
- Nothing is bundled or sold; you supply everything.

Nova Edge is built for developers and self-hosters. Its networking layer uses
widely used open-source components, with original scanning, deployment, diagnostics,
and interface built on top.
```

## 6. Screenshot plan (order is the argument)

Current screenshots lead with the **connect** screen - that is the "proxy client"
image Apple pattern-matches. Re-shoot in this order, each with a caption overlay:

1. **Nova Radar** mid-scan (the radar sweep + alive/dead/latency counters).
   Caption: "Scan for the fastest clean edge IPs."
2. **Deploy your own** (the Cloudflare deploy / worker list).
   Caption: "Deploy your own Cloudflare Worker in taps."
3. **Toolkit / Logs** (the core log or routing/diagnostics screen).
   Caption: "See exactly what your network is doing."
4. **Servers / configs** (managing your own configs).
   Caption: "Manage the infrastructure you control."
5. **Dashboard/connect** LAST.
   Caption: "Connect through your own edge."

Same order for iPad. (Producing the actual captioned images is a design task - hand
this plan to the design-expert agent.)

## 7. App Review notes (what to write in "Notes" for the reviewer)

```
Nova Edge is a self-hosting + diagnostics toolkit, not a proxy/VPN service. It
bundles and sells nothing: the user deploys and connects to their OWN Cloudflare
Worker with their OWN keys. Its differentiators over generic clients:

- Nova Radar: an on-device clean-IP scanner (fetches candidate IP ranges, verifies
  each over TCP/TLS, ranks by latency, applies the best in one tap).
- Deploy your own: sign in to your own Cloudflare account and deploy/manage a Worker
  from inside the app.
- A network toolkit and config builder for your own setup.

No account or purchase is needed to review. A working demo configuration and a
short screen recording of Radar + Deploy are available on request - please ask and
we will provide them immediately.
```

Have the demo config + a 30-60s screen recording of **Radar scanning** and **Deploy**
ready to attach; those two features are the case that this is not a duplicate.

## 8. Identity / account moves (these matter more than the copy)

- **Organization account.** VPN-capable apps require org enrollment (Guideline 5.4),
  and an org account distances you from the flagged individual-account history. This
  is likely a prerequisite, not optional.
- **Fresh app record** on the org account. The current record (App ID 6785367637)
  carries the 4.3 + terminated-account history; a clean record starts without it.
- **Break the binary/concept fingerprint.** Distinct app-layer code, distinct UI
  paradigm, new bundle id, new name - so the similarity engine doesn't match the
  terminated-account app. The shared sing-box/xray core is the risk; the more the
  app *around* it diverges, the better.
- **Do NOT resubmit the same binary** on the current account. Repeated 4.3 +
  terminated-account resubmissions can jeopardise the developer account itself.

## 9. Honest odds

Even executed fully, 4.3 + terminated-account is one of the hardest App Store
rejections, and an appeal already failed. Treat App Store as a *maybe* that needs
all of the above, and keep the paths that work today in parallel: **TestFlight**
(dev + up to 10k external testers, no 4.3 gate), sideload/AltStore, and EU
alternative marketplaces.
