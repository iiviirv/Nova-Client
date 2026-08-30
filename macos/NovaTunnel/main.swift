import Foundation
import NetworkExtension

// A system extension is a real executable, not a plug-in bundle the way the
// iPhone's app extension is, so it needs an entry point. This is the whole of
// it: hand the process to NetworkExtension, which finds the provider class
// named in Info.plist, and then park the main thread on the run loop.
autoreleasepool {
  NEProvider.startSystemExtensionMode()
}

dispatchMain()
