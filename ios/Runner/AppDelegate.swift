import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Quiet, prompt-free authorization so the tunnel extension can post a
    // "Nova disconnected" note to Notification Center if the VPN drops
    // unexpectedly. Provisional never shows a permission dialog; the user can
    // promote or silence it from the first delivered notification.
    UNUserNotificationCenter.current()
      .requestAuthorization(options: [.alert, .provisional]) { _, _ in }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    if let registrar = registry.registrar(forPlugin: "NovaProxyHost") {
      NovaProxyHost.register(with: registrar)
    }
  }
}
