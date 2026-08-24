# Handoff (Nova Server / panel): emit xhttp under `target=nova`

**For:** whoever works on the Nova Server panel (the Cloudflare Worker that
serves `/sub`).
**From:** the Nova-Client side. The client already runs xhttp; this is the one
server change that makes an xhttp node reach Nova-Client users.

This is the same shape of problem, and the same fix, as
[`handoff-panel-mieru-target-nova.md`](./handoff-panel-mieru-target-nova.md),
which has already shipped: mieru now arrives under `target=nova` and works.

## The problem, verified against a live panel

Checked 2026-08-22 against
`https://s26ultra.mayata.sbs/sub?u=caa1dd205227b0136c8ee40e`, a panel with one
xhttp node enabled:

| `target=` | body format | xhttp present? |
| --- | --- | --- |
| `v2rayng` | base64 share links | **yes** |
| (none) | base64 share links | **yes** |
| `nova` | sing-box JSON | no |
| `hiddify` | sing-box JSON | no |
| `singbox` | sing-box JSON | no |

The node itself is fine. Every sing-box JSON target drops it, which is correct
for `hiddify` and `singbox` (sing-box genuinely has no xhttp outbound, see
[`xray-core-scope.md`](./xray-core-scope.md)) and wrong for `nova`:

**Nova-Client ships an Xray core alongside sing-box precisely for this.** An
xhttp node is run on Xray behind a local SOCKS inbound and joins the sing-box
pool as a socks outbound, so it connects, gets measured by the lightning test,
and can be auto-selected like any other server. `target=nova` is the only
target that can say so.

This is the second time an operator has enabled a protocol, seen it in one
client and not in Nova, and had nothing a client release could do about it.

## The change

When building the outbounds for **`target=nova`**, include an xhttp node as a
`vless` outbound whose `transport.type` is `xhttp`. From the share link the
`v2rayng` target already emits for this node:

```
vless://5c5abeb5-…@104.16.4.103:2053?encryption=none&type=xhttp
  &path=%2Fdev%2Fver%2Fnewidea2.3&mode=auto
  &security=tls&sni=cfct.mayata.sbs&fp=chrome#test (Xhttp) - clean IP
```

the JSON is:

```json
{
  "type": "vless",
  "tag": "test (Xhttp) - clean IP",
  "server": "104.16.4.103",
  "server_port": 2053,
  "uuid": "5c5abeb5-20ff-4980-bd3c-5948aae18b82",
  "transport": {
    "type": "xhttp",
    "path": "/dev/ver/newidea2.3",
    "mode": "auto"
  },
  "tls": {
    "enabled": true,
    "server_name": "cfct.mayata.sbs",
    "utls": { "enabled": true, "fingerprint": "chrome" }
  }
}
```

What the client's importer reads (`singbox_outbound_import.dart`):

- `transport.type` -> the node's network. The literal string `xhttp` is what
  routes it to the Xray core; `splithttp` is accepted as an alias.
- `transport.path`, and `transport.host` or `transport.headers.Host` if the
  node is fronted.
- `transport.mode` if present (`auto` is the default).
- `tls.server_name` -> SNI, `tls.utls.fingerprint` -> the uTLS fingerprint,
  `tls.insecure` -> allow-insecure.

Do not invent a new shape: the importer was written against sing-box's
transport block, which is what every other node in the same body already uses.

Also add its tag to the `urltest` / `selector` group's outbound list, exactly as
the other nodes are, so auto-select can pick it.

**Only for `target=nova`.** `target=singbox` and `target=hiddify` must keep
dropping xhttp: a stock sing-box core rejects the config outright, and emitting
it there would break subscriptions that work today.

## How to check it worked

```sh
curl -s "https://<panel>/sub?u=<user>&target=nova" | \
  python3 -c "import json,sys; print([(o['type'], o.get('transport',{}).get('type')) \
    for o in json.load(sys.stdin)['outbounds']])"
```

The xhttp node should appear as `('vless', 'xhttp')`. In Nova-Client it then
shows in the server list with a real ping from the lightning test, rather than
being absent.


## Still broken on 2026-08-24, with a side-by-side diff

Checked against a live Nova Server panel,
`https://s26ultra.mayata.sbs/sub?u=caa1dd205227b0136c8ee40e`, fetching both
bodies and diffing them by `server:port`.

The plain subscription carries nine servers. `target=nova` carries nine. They
are not the same nine:

| | plain | `target=nova` |
| --- | --- | --- |
| `vless` **xhttp** `104.16.4.103:2053` | present | **missing** |
| `mieru iphone17pro.mayata.sbs:44674` | missing | present |

Everything else matches. So this is not a case of the panel lacking an xhttp
inbound: the operator has one configured, the plain body advertises it, and the
Nova target drops exactly that node and nothing else.

The client side has been ready for a long time. It runs xhttp through the Xray
core and measures it alongside the sing-box nodes; there is simply nothing to
run, because the node never arrives.
