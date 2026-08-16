// Package novaxray is a minimal gomobile wrapper around xray-core, for the
// Phase-1 spike proving Nova can run an Xray-only transport (xhttp / SplitHTTP)
// on Android. It exposes just start/stop/version with gomobile-safe signatures.
//
// The blank import registers every Xray inbound/outbound/transport (including
// SplitHTTP/xhttp), so a config that uses them loads.
package novaxray

import (
	"bytes"
	"sync"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu       sync.Mutex
	instance *core.Instance
)

// Version returns the embedded Xray core version.
func Version() string { return core.Version() }

// Start boots an Xray instance from a JSON config. Any previous instance is
// stopped first. Returns the error string (empty on success) so gomobile can
// surface it simply.
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
