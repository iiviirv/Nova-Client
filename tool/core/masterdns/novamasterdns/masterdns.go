// Package novamasterdns is the gomobile face of the MasterDNS engine, bound into
// Novacore beside sing-box and Xray so the iOS Network Extension can run a DNS
// tunnel in the one Go runtime it is allowed.
//
// It only forwards. The engine itself sits under internal/ in its own module,
// so the code that drives it has to live inside that module; see
// tool/core/masterdns/mdnsmobile.
//
// Routing is the open question on iOS. The engine's traffic is DNS, and the
// tunnel hijacks DNS, so its queries must not enter the tunnel this same
// process provides. sing-box keeps its own sockets out by binding them to the
// physical interface; the engine does not bind at all. Whether an unbound
// socket in the extension bypasses the tunnel has to be checked on a device,
// not assumed.
package novamasterdns

import "masterdnsvpn-go/mobile"

// Start runs the engine. See mobile.Start.
func Start(configJSON, resolversPath, logPath string) error {
	return mobile.Start(configJSON, resolversPath, logPath)
}

// Stop shuts the engine down. It never stops on its own.
func Stop() {
	mobile.Stop()
}

// Running reports whether the engine is started.
func Running() bool {
	return mobile.Running()
}
