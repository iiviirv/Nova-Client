# Handoff (Nova Server / panel): emit mieru under `target=nova`

**For:** whoever works on the Nova Server panel (the Cloudflare Worker that
serves `/sub`).
**From:** the Nova-Client side. The client is done and tested; this is the
one server change that makes mieru reach Nova-Client users.

## The problem, verified against the live panel

The user's mieru node is enabled ("mieru (Hiddify only)" toggle) and works in
Karing via the Hiddify subscription. It never reaches Nova-Client because the
panel only emits mieru for one target. Checked on 2026-08-18 against
`https://vpn.novaproxy.qzz.io/sub?u=908091153be8838dbe794273`:

| `target=` | body format | mieru present? |
| --- | --- | --- |
| `hiddify` | sing-box JSON | **yes** |
| `nova` | sing-box JSON | no |
| `singbox` | sing-box JSON | no |
| `v2rayng` | base64 share links | no |
| (none) | base64 share links | no |

So a Nova-Client user is never sent the node, and no client release can fix
that.

## The change

When building the outbounds for **`target=nova`**, include the mieru outbound
under the same conditions it is included for `target=hiddify` (the per-user
mieru toggle). Emit it in **exactly the shape the Hiddify target already
produces**, which is:

```json
{
  "type": "mieru",
  "tag": "Azad mieru",
  "server": "vpn.novaproxy.qzz.io",
  "server_port": 6600,
  "portBindings": [{ "port": 6600, "protocol": "TCP" }],
  "username": "<user's mieru username>",
  "password": "<user's mieru password>",
  "multiplexing": "MULTIPLEXING_LOW"
}
```

Do not invent a new shape. The client's importer was written against this one
and reads:

- `username` (the client stores it in its uuid slot, as it does for
  socks/naive) and `password`,
- the transport from `portBindings[0].protocol` (`TCP` or `UDP`),
- `multiplexing` (defaults to `MULTIPLEXING_LOW` if absent).

Also add it to the `urltest`/`selector` group's outbound list, exactly as the
Hiddify target does, so auto-select can measure it.

## Where the toggle lives

The per-user setting is currently labelled **"mieru (Hiddify only)"**. Once
`target=nova` also honours it, that label is wrong. Suggest renaming it to
plain **"mieru"** (or "mieru (Hiddify + Nova)"), otherwise users will keep
believing it does not apply to Nova.

## Out of scope for the panel

- Emitting a `mieru://` share link for the base64 targets (`v2rayng`, no
  target). Not needed: Nova-Client reads `target=nova` (JSON) as of the
  subscription-import fix on 2026-08-19, and the base64 targets are for other
  apps that mostly do not speak mieru anyway.
- Anything about the mita server itself. It already works (Karing connects).

## How to verify from the client side, once shipped

```
curl -s 'https://vpn.novaproxy.qzz.io/sub?u=<uid>&target=nova' \
  | python3 -c 'import json,sys; print([o["type"] for o in json.load(sys.stdin)["outbounds"]])'
```

`mieru` must appear in that list. Then in Nova-Client, refresh the Nova
subscription: an "Azad mieru" node shows up and connects. The client-side proof
that this shape imports correctly is
`test/nova_target_subscription_test.dart` (`mieruReadiness`).
