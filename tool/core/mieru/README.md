# mieru sing-box outbound (vendored from enfein/mbox)

`outbound.go` and `option_mieru.go` are taken verbatim from
https://github.com/enfein/mbox (a GPL-3.0 sing-box fork with mieru support),
`protocol/mieru/outbound.go` and `option/mieru.go`. The core build scripts copy
them into the cloned sing-box tree, add a `TypeMieru` constant, register the
outbound, and add `github.com/enfein/mieru/v3`. Verified to compile against the
pinned sing-box v1.13.13. See docs/mieru-support.md.
