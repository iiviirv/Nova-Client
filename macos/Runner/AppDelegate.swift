import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Closing the window must not end Nova.
  ///
  /// Nova lives in the menu bar: the red button hides the window, the tunnel
  /// keeps running, and the only thing that actually quits is Quit in the tray
  /// menu (which disconnects first). With this returning true the app died with
  /// its window, taking the connection with it, which is not what closing a
  /// window means for anything else that runs in the menu bar.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// Clicking the Dock icon brings the window back.
  ///
  /// Closing the window only hides it (see above), and with nothing handling
  /// reopen the Dock icon did nothing at all afterwards: the only way back in
  /// was Show Nova in the menu bar, which is not where anyone looks first.
  /// macOS calls this with hasVisibleWindows false in exactly that state.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
