import Flutter
import Foundation
import NetworkExtension

/// iOS implementation of the `nova.proxy/control` MethodChannel + `nova.proxy/events`
/// EventChannel that the Flutter `SingboxProxyController` drives. It manages the
/// Packet Tunnel (the sing-box Network Extension) via NETunnelProviderManager:
/// the config is handed to the extension through the shared App Group, and the
/// connection state is streamed back from NEVPNStatus.
final class NovaProxyHost: NSObject, FlutterStreamHandler {
  static let appGroup = "group.online.novaproxy.novaClient"
  static let tunnelBundleId = "online.novaproxy.novaClient.NovaTunnel"

  private var eventSink: FlutterEventSink?
  private var manager: NETunnelProviderManager?

  static func register(with registrar: FlutterPluginRegistrar) {
    let host = NovaProxyHost()
    let control = FlutterMethodChannel(name: "nova.proxy/control", binaryMessenger: registrar.messenger())
    control.setMethodCallHandler(host.handle)
    let events = FlutterEventChannel(name: "nova.proxy/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(host)

    NotificationCenter.default.addObserver(
      host, selector: #selector(host.statusChanged),
      name: .NEVPNStatusDidChange, object: nil)
  }

  // MARK: - MethodChannel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any],
            let config = args["configJson"] as? String else {
        result(FlutterError(code: "args", message: "configJson required", details: nil))
        return
      }
      start(config: config, result: result)
    case "stop":
      manager?.connection.stopVPNTunnel()
      result(nil)
    case "status":
      result(stateName(manager?.connection.status ?? .invalid))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(config: String, result: @escaping FlutterResult) {
    // Write the config where the extension can read it (shared App Group).
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      result(FlutterError(code: "appgroup", message: "App Group not configured", details: nil))
      return
    }
    do {
      try config.write(to: container.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    } catch {
      result(FlutterError(code: "write", message: error.localizedDescription, details: nil))
      return
    }

    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self else { return }
      if let error { result(FlutterError(code: "load", message: error.localizedDescription, details: nil)); return }
      let mgr = managers?.first ?? NETunnelProviderManager()
      let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
      proto.providerBundleIdentifier = Self.tunnelBundleId
      proto.serverAddress = "Nova"
      mgr.protocolConfiguration = proto
      mgr.localizedDescription = "Nova"
      mgr.isEnabled = true
      mgr.saveToPreferences { error in
        if let error { result(FlutterError(code: "save", message: error.localizedDescription, details: nil)); return }
        // Reload so the saved configuration is applied before starting.
        mgr.loadFromPreferences { _ in
          self.manager = mgr
          do {
            try mgr.connection.startVPNTunnel()
            result(nil)
          } catch {
            result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  // MARK: - State stream

  @objc private func statusChanged() {
    let status = manager?.connection.status ?? .invalid
    emit(["type": "state", "value": stateName(status)])
    // Live traffic reporting from the extension can be added via the App Group
    // or a libbox command client; state alone is enough to drive the UI for now.
  }

  private func stateName(_ s: NEVPNStatus) -> String {
    switch s {
    case .connected: return "connected"
    case .connecting, .reasserting: return "connecting"
    case .disconnecting: return "disconnecting"
    default: return "disconnected"
    }
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { self.eventSink?(event) }
  }

  // FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
