# Wire probe

Answers one question: does Nova put the same bytes on the wire as Xray does?

Iran's DPI now fingerprints the ClientHello, so "we send the same finalmask as
the reference client" is not enough. On 2026-09-10 this rig found that Nova's ClientHello was
short two cipher suites, which changes the JA3/JA4 fingerprint and makes Nova
distinguishable from another bypass client no matter how correct the fragmentation is.

## Run it

    # 1. a listener that logs recv boundaries and parses the TLS records
    python3 tool/wireprobe/listen.py 19443 NOVA /tmp/nova.json &

    # 2. Nova's real config, built by the app's own builder, aimed at it
    dart run tool/wireprobe/nova_config.dart 19443 > /tmp/nova_cfg.json
    ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
    ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
      ./assets/bin/sing-box-macos-arm64 run -c /tmp/nova_cfg.json &

    # 3. drive one connection through it
    curl -s -x socks5h://127.0.0.1:18080 --max-time 5 https://example.com/ -o /dev/null

Concatenating the record payloads gives the ClientHello; compare cipher list,
extension order and supported_groups against a real Xray run set up the same
way. The listener is not a TLS server, so the handshake dies right after the
ClientHello, which is all the DPI sees anyway.

## Gotchas that cost time

- The core refuses to start without `ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER`
  and `ENABLE_DEPRECATED_LEGACY_DNS_SERVERS`. Both are on the way out in
  sing-box 1.14, so this needs the typed-DNS migration eventually.
- `timeout` is not a macOS command.
- The published Xray release lags master. 26.3.27 has no `lengths` array and
  reports `LengthMin can't be 0` for any mask using it, which looks like a
  rejection of the mask and is not. Master's rule is that only the LAST entry
  may not be 0, so a leading 0 is legal.
