# Handoff (Nova Server / panel): emit AmneziaWG under `target=nova`

**For:** whoever works on the Nova Server panel (the Worker that serves `/sub`).
**From:** the Nova-Client side. The client half is done and shipped; this is the
server change that lets an AmneziaWG node reach Nova-Client users.

## What was asked for

A tester with AmneziaWG in their subscription found it reached no client. It
had to be pasted in by hand as an `awg://` link, and even then it sat outside
the subscription, so it did not refresh with the others.

The request: an AmneziaWG server in a user's subscription should arrive through
the Nova subscription like any other node, appear in the config list beside
them, and take part in the lightning test.

## The client half, done

Nova-Client 1.20.0-beta reads AmneziaWG from a `target=nova` body.

The Nova target is a sing-box config document rather than a list of share
links, and sing-box 1.11 moved WireGuard and AmneziaWG out of `outbounds` into
their own `endpoints` array. The client's importer only read `outbounds`, so
the array holding those servers was never looked at. It reads `endpoints` now,
rebuilds each entry into the node the rest of the app understands (junk
parameters included), and puts it in the measuring pool as an endpoint so the
lightning test covers it.

## The server half, outstanding

Checked on 2026-08-24 against a live Nova Server panel
(`https://s26ultra.mayata.sbs/sub?u=caa1dd205227b0136c8ee40e`): the
`target=nova` body has `"endpoints": []` and no `wireguard` or `awg` entry
anywhere, and the plain body carries no `awg://` or `wireguard://` link either.

That panel has no AmneziaWG inbound configured, so it does not prove the panel
would omit one. What it does show is that nothing was verifiable end to end, and
a panel WITH an AmneziaWG inbound is needed to tell "the panel drops it" apart
from "there was nothing to drop".

## What to emit

Under `target=nova`, an AmneziaWG inbound should appear in the top-level
`endpoints` array, not in `outbounds`, in the shape sing-box 1.11+ expects:

```json
{
  "type": "awg",
  "tag": "<node name>",
  "private_key": "<client private key>",
  "address": ["10.8.0.2/32"],
  "mtu": 1420,
  "jc": 4, "jmin": 40, "jmax": 70, "s1": 15, "s2": 20,
  "peers": [{
    "public_key": "<server public key>",
    "address": "<server host>",
    "port": 51820,
    "allowed_ips": ["0.0.0.0/0"],
    "persistent_keepalive_interval": 25
  }]
}
```

`type` is `awg` when junk parameters are present and `wireguard` when they are
not; the client accepts both. The tag becomes the name in the server list. The
node also has to be listed in the `urltest` group's outbounds so the auto
selector and the lightning test include it, exactly as the other nodes are.

## How to check it worked

Fetch `?target=nova`, confirm the node is under `endpoints`, then import the
same URL in Nova-Client: it should appear in the config list with the others and
show a number after a lightning test rather than "not testable".
