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

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
