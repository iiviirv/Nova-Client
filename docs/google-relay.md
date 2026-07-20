# Google relay: three ways to stay reachable

Nova's "Google relay" makes your traffic look like ordinary `www.google.com`
traffic to your ISP. There are three layers, from lightest to heaviest. Pick the
lightest one that solves your problem.

| Mode | Carries | Speed | Needs |
|------|---------|-------|-------|
| **Relay** (default) | The config only (subscription + `/admin` API) | Fine (small JSON) | A Google Apps Script, or a node `/relay` |
| **Direct (domain fronting)** | The relay's own connection, and Google-owned hosts | Fast | Nothing extra (built in) |
| **Full tunnel** | Real TCP traffic (a local SOCKS5) | Slow | Your own VPS with the tunnel exit on |

All three are set up on **Settings → Google relay**.

---

## 1. Relay (the config layer)

This is what Nova has always had. A small Google Apps Script (or your node's
`/relay` endpoint) fetches your subscription and reaches your `/admin` API on your
behalf, so the config layer keeps working when your panel's domain is blocked.

- Paste the Apps Script `/exec` URL (or a node `/relay` URL) into **Relay URL**.
- Paste the **Auth key** if the endpoint needs one (a direct node `/relay` does; a
  Google Apps Script usually injects it).
- Turn on **Allow insecure certificate** only for a self-hosted node with a
  self-signed certificate.
- Tap **Test connection**, then turn on **Enable relay**.

The honest limit: this carries the **config, not the VPN tunnel**. Your actual
connection still needs working exit nodes (a VPS with Reality, or a direct IP).

---

## 2. Direct (domain fronting)

Turn on **Route via Google edge (domain fronting)**.

Instead of connecting to the relay's address (which a DPI box can block by SNI),
Nova connects straight to a **Google edge IP** and hand-shakes as
`www.google.com`, while asking for the real host inside the encrypted stream.
Google's frontend routes by that inner host. Your ISP only sees a connection to
`www.google.com`, which it cannot block without breaking Google.

- **Front name (SNI)**: `www.google.com` (leave it; blocking it breaks Google).
- **Front edge IP**: leave blank and tap **Auto-pick a live edge**, or paste a
  Google `ghs` IP like `216.239.38.120`.
- Tap **Test direct front**. A pass ("Domain fronting works") means the edge
  routes by host on your network.

This keeps the relay reachable even if `script.google.com` itself is SNI-blocked,
and there is no Apps Script quota on this path. It only reaches Google-owned /
CDN-co-tenant hosts, so it does not turn Nova into a general web proxy on its own.

---

## 3. Full tunnel (last resort)

Turn on **Full tunnel through Google**. This is the only mode that carries **real
traffic**, not just the config.

Nova opens a **local SOCKS5 proxy** on `127.0.0.1`. Each TCP flow through it is
carried, as tunnel ops, out through your **own VPS exit**, which talks to the
internet. To your ISP it looks like Google traffic. It can get you online when
every normal node is blocked, but it is **slow by nature**: each chunk is a
round-trip through Google.

### On the node (one time)

Your Nova VPS node must have the tunnel exit turned on:

```
POST /admin/tunnel   { "action": "generate" }   # enables it and returns a key
```

(Or use the node panel's tunnel toggle.) Copy the returned key and the
`https://<your-node>/tunnel` URL.

### In the app

- **Tunnel exit URL**: `https://<your-node>/tunnel` (or an Apps Script `/exec`
  that forwards to it).
- **Auth key**: the key from the node.
- **Local SOCKS5 port**: `1080` (or any free port).
- Tap **Test tunnel**. A pass ("Tunnel is carrying traffic") means
  SOCKS5 → tunnel op → node exit → internet all work.
- Tap **Start tunnel**, then point an app (or the system proxy) at
  `SOCKS5 127.0.0.1:1080`.

The tunnel rides the same transport as the relay above, so if **domain fronting**
is on, the tunnel is fronted through Google too.

### Reality check

The full tunnel is for **reachability, not speed**. For everyday use, a real
VPS/Reality/Hysteria2 node in your subscription is always faster. Reach for the
full tunnel only when everything else is blocked.
