// Package novaxray is a minimal gomobile wrapper around xray-core, for running
// Nova's Xray-only transports (xhttp / SplitHTTP) as a second core alongside
// sing-box. It exposes start/stop/version plus a socket protector so Xray's own
// outbound sockets stay off the VPN route.
//
// Data path (Android): the VpnService TUN is owned by sing-box, which forwards
// everything to a local SOCKS inbound that Xray serves; Xray then dials the
// xhttp server. Xray's dial to that server MUST be protected, or it would be
// captured by the TUN and loop forever, hence [SetProtector].
//
// The blank import registers every Xray inbound/outbound/transport (xhttp too).
package novaxray

import (
	"bytes"
	"sync"
	"syscall"

	xlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet"
)

var (
	mu         sync.Mutex
	instance   *core.Instance
	registered bool

	logMu     sync.RWMutex
	logger    Logger
	logHooked bool
)

// Logger is implemented on the platform side so Xray's own log lines can be
// shown in the app's core log next to sing-box's (the app's Core log stream is
// otherwise libbox-only, which left Xray-only failures like an xhttp transport
// error invisible). One string per record; the platform tags/levels it.
type Logger interface {
	Log(line string)
}

// SetLogger installs [l] as the sink for Xray's log records and, on first call,
// registers a core log handler that forwards to it. A nil logger detaches the
// sink (the handler stays registered but drops records). Safe to call before or
// after Start.
func SetLogger(l Logger) {
	logMu.Lock()
	logger = l
	hook := !logHooked && l != nil
	if hook {
		logHooked = true
	}
	logMu.Unlock()
	if hook {
		// Replaces whatever handler app/log installed from the config's `log`
		// policy; we don't use Xray's own console/file logging, so forwarding
		// every record to the app is exactly what we want. The config still sets
		// loglevel (warning by default), which gates what reaches this handler.
		xlog.RegisterHandler(xrayLogHandler{})
	}
}

type xrayLogHandler struct{}

func (xrayLogHandler) Handle(msg xlog.Message) {
	if msg == nil {
		return
	}
	logMu.RLock()
	l := logger
	logMu.RUnlock()
	if l != nil {
		l.Log(msg.String())
	}
}

// Protector is implemented on the platform side (Android VpnService.protect) so
// Xray's outbound sockets bypass the VPN route. Without it the TUN -> sing-box
// -> Xray -> server dial loops back through the TUN.
type Protector interface {
	Protect(fd int) bool
}

// SetProtector installs [p] as the controller for every socket Xray dials. Safe
// to call once before Start; later calls are ignored. A nil protector is a no-op
// (desktop, where sockets are not TUN-captured).
func SetProtector(p Protector) {
	mu.Lock()
	defer mu.Unlock()
	if p == nil || registered {
		return
	}
	_ = internet.RegisterDialerController(
		func(network, address string, c syscall.RawConn) error {
			return c.Control(func(fd uintptr) { p.Protect(int(fd)) })
		})
	registered = true
}

// Version returns the embedded Xray core version.
func Version() string { return core.Version() }

// Start boots an Xray instance from a JSON config, stopping any previous one.
// Returns the error string (empty on success) so gomobile can surface it simply.
func Start(configJSON string) string {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	cfg, err := core.LoadConfig("json", bytes.NewReader([]byte(configJSON)))
	if err != nil {
		return "load: " + err.Error()
	}
	inst, err := core.New(cfg)
	if err != nil {
		return "new: " + err.Error()
	}
	if err := inst.Start(); err != nil {
		return "start: " + err.Error()
	}
	instance = inst
	return ""
}

// Stop closes the running instance, if any.
func Stop() string {
	mu.Lock()
	defer mu.Unlock()
	if instance == nil {
		return ""
	}
	err := instance.Close()
	instance = nil
	if err != nil {
		return err.Error()
	}
	return ""
}
