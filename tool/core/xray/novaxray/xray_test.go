package novaxray

import (
	"strings"
	"testing"
)

// An xhttp (SplitHTTP) VLESS outbound plus a local socks inbound. If Xray was
// built with the xhttp transport registered and our config shape is valid, Start
// returns "" (outbounds are lazy, so no live server is needed to prove the core
// accepts and runs an xhttp config).
const xhttpConfig = `{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag":"socks-in","listen":"127.0.0.1","port":38080,"protocol":"socks","settings":{"udp":true}}],
  "outbounds": [{
    "tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"104.17.0.1","port":443,"users":[{"id":"00000000-0000-4000-8000-000000000000","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","security":"tls",
      "tlsSettings":{"serverName":"example.workers.dev"},
      "xhttpSettings":{"host":"example.workers.dev","path":"/xh"}}
  }]
}`

func TestVersion(t *testing.T) {
	if Version() == "" {
		t.Fatal("empty version")
	}
	t.Logf("xray version %s", Version())
}

func TestXhttpConfigStarts(t *testing.T) {
	if err := Start(xhttpConfig); err != "" {
		if strings.Contains(err, "xhttp") || strings.Contains(err, "unknown transport") {
			t.Fatalf("xhttp transport NOT registered: %s", err)
		}
		t.Fatalf("xhttp config failed to start: %s", err)
	}
	t.Log("xhttp config started (socks inbound up, xhttp outbound accepted)")
	if err := Stop(); err != "" {
		t.Fatalf("stop failed: %s", err)
	}
}
