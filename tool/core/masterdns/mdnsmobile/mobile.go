// Package mobile runs the MasterDNS client engine from inside another program,
// rather than as its own process.
//
// It exists for iOS. An iPhone app may not start a second process, and the
// Network Extension already holds a Go runtime for sing-box, so the engine has
// to be compiled into that same runtime. The engine lives under internal/,
// which only code inside this module may import, so this package is copied
// into the MasterDnsVPN tree at build time (see
// tool/core/build-combined-core-ios.sh) and a thin wrapper in the sing-box
// tree imports it.
package mobile

import (
	"context"
	"encoding/base64"
	"errors"
	"sync"
	"time"

	"masterdnsvpn-go/internal/client"
	"masterdnsvpn-go/internal/config"
)

var (
	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
)

// Start brings the engine up with configJSON, the engine's own upper-case
// JSON, and the resolvers listed one per line in the file at resolversPath.
//
// Resolvers travel as a file because the engine cannot read them from JSON:
// that field is excluded from decoding.
//
// logPath is where the engine writes its log, or empty for none. On iOS the
// extension's standard output goes nowhere, so a file in the shared container is
// the only way anyone sees why a tunnel did not form.
//
// It returns once the engine is set up. The tunnel forms in the background, and
// the signal that it has is the engine's SOCKS port opening, which only happens
// once a working path through the resolvers exists.
func Start(configJSON, resolversPath, logPath string) error {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()

	path := resolversPath
	cfg, err := config.LoadClientConfigFromJSONBase64WithOverrides(
		base64.StdEncoding.EncodeToString([]byte(configJSON)),
		config.ClientConfigOverrides{ResolversFilePath: &path},
	)
	if err != nil {
		return err
	}
	app, err := client.BootstrapLoadedConfig(cfg, logPath)
	if err != nil {
		return err
	}
	if app == nil {
		return errors.New("masterdns: the engine did not start")
	}

	ctx, c := context.WithCancel(context.Background())
	d := make(chan struct{})
	cancel, done = c, d
	go func() {
		defer close(d)
		_ = app.Run(ctx)
	}()
	return nil
}

// Stop shuts the engine down. The engine never stops by itself, even when it
// cannot reach anything, so this is the only way it ends.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if cancel == nil {
		return
	}
	cancel()
	cancel = nil
	// Its shutdown sends a short close burst to the server. Waiting for it keeps
	// a restart from racing the old session, but not forever: a tunnel being
	// torn down should not hold the extension up.
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
	done = nil
}

// Running reports whether an engine is currently started.
func Running() bool {
	mu.Lock()
	defer mu.Unlock()
	return cancel != nil
}
