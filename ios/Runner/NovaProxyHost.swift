import Flutter
import Foundation
import Novacore
import NetworkExtension
import Network
import CoreTelephony
import WidgetKit

/// iOS implementation of the `nova.proxy/control` MethodChannel + `nova.proxy/events`
/// EventChannel that the Flutter `SingboxProxyController` drives. It manages the
/// Packet Tunnel (the sing-box Network Extension) via NETunnelProviderManager:
/// the config is handed to the extension through the shared App Group, and the
/// connection state is streamed back from NEVPNStatus.
final class NovaProxyHost: NSObject, FlutterStreamHandler {
  static let appGroup = "group.tech.innovatenorth.novaedge"
  static let tunnelBundleId = "tech.innovatenorth.novaedge.NovaTunnel"

  private var eventSink: FlutterEventSink?
  private var manager: NETunnelProviderManager?
  private var statusClient: NovacoreCommandClient?
  private var logClient: NovacoreCommandClient?
  private var groupClient: NovacoreCommandClient?
  // Tails the NE's xray.log (Xray's own log lines, written from the extension) and
  // folds them into the Core log next to sing-box's. libbox's CommandLog only
  // carries sing-box, so without this Xray-only failures are invisible on iOS.
  private var xrayLogTimer: DispatchSourceTimer?
  private var xrayLogSeen = 0
  private var libboxReady = false
  private let measure = NovaMeasure()

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
      // Optional bundled rule-set files (name -> bytes), written next to the
      // config so the lean iOS config can reference them as local rule-sets.
      let ruleSets = (args["ruleSets"] as? [String: FlutterStandardTypedData]) ?? [:]
      // Present only for an xhttp node: the Xray core config the extension runs
      // alongside the sing-box TUN->SOCKS bridge.
      let xrayConfig = args["xrayConfigJson"] as? String
      // Cosmetic profile name for the home-screen widget.
      profileLabel = (args["label"] as? String)?.isEmpty == false
        ? (args["label"] as? String) : nil
      start(config: config, ruleSets: ruleSets, xrayConfig: xrayConfig,
            autoReconnect: (args["autoReconnect"] as? Bool) ?? false,
            result: result)
    case "stop":
      stopTunnel(result: result)
    case "status":
      // Load the existing tunnel manager if we don't have it yet (e.g. the app
      // was relaunched while the VPN kept running), so we report the REAL status
      // instead of "disconnected".
      loadManagerIfNeeded { [weak self] in
        guard let self else { result("disconnected"); return }
        let status = self.manager?.connection.status ?? .invalid
        if status == .connected {
          self.startStatusClient()
          self.startLogClient()
          self.startGroupClient()
        }
        result(self.stateName(status))
      }
    case "networkInfo":
      result(Self.networkInfo())
    case "measure":
      // "Test all servers through the core": start a second, tunnel-less core
      // in THIS process (not the extension) and answer once it is up. Dart then
      // drives the run over the core's Clash API and calls measureCancel to
      // stop it. Refused while the tunnel is up or coming up: libbox keeps one
      // command socket per App Group base path, and every dial would go through
      // the tunnel anyway.
      guard let args = call.arguments as? [String: Any],
            let config = args["configJson"] as? String else {
        result(FlutterError(code: "args", message: "configJson required", details: nil))
        return
      }
      let xrayConfig = args["xrayConfigJson"] as? String
      loadManagerIfNeeded { [weak self] in
        guard let self else { result(FlutterError(code: "gone", message: "host gone", details: nil)); return }
        let status = self.manager?.connection.status ?? .invalid
        if status == .connected || status == .connecting || status == .reasserting || status == .disconnecting {
          result(FlutterError(code: "busy", message: "Disconnect first to measure all servers.", details: nil))
          return
        }
        self.ensureNovacoreSetup()
        self.measure.start(config: config, xrayConfig: xrayConfig,
                           ready: { result(nil) },
                           fail: { why in result(FlutterError(code: "measure_failed", message: why, details: nil)) })
      }
    case "measureCancel":
      measure.cancel()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Carrier identity for per-ISP optimization, mirroring the Android
  /// `networkInfo` method: `{ mccMnc, sim, name }`.
  ///
  /// Apple deprecated CTCarrier in iOS 16 and it now reports "65535" (or nil) for
  /// mobile country/network codes on modern devices, with a carrier name of "--".
  /// There is no replacement API. We filter those sentinel values out and return
  /// an empty map, which the Dart side treats as "no carrier -> use the default
  /// profile". So this yields a real match only on older iOS / where the OS still
  /// reports it, and degrades cleanly everywhere else (no regression).
  private static func networkInfo() -> [String: String] {
    let net = CTTelephonyNetworkInfo()
    let providers = net.serviceSubscriberCellularProviders
    func usable(_ c: CTCarrier) -> Bool {
      guard let mcc = c.mobileCountryCode, let mnc = c.mobileNetworkCode else {
        return false
      }
      return !mcc.isEmpty && mcc != "65535" && !mnc.isEmpty && mnc != "65535"
    }
    let carrier = providers?.values.first(where: usable)
    guard let c = carrier, let mcc = c.mobileCountryCode,
          let mnc = c.mobileNetworkCode else {
      return [:]
    }
    let code = mcc + mnc
    return ["mccMnc": code, "sim": code, "name": c.carrierName ?? ""]
  }

  /// The token the Dart config uses in local rule-set paths; replaced with the
  /// real App Group container path here (the app and extension share it, so an
  /// absolute path written by the app is valid inside the extension too).
  private static let ruleSetBaseToken = "__NOVA_BASE__"

  private func start(config: String, ruleSets: [String: FlutterStandardTypedData],
                     xrayConfig: String?, autoReconnect: Bool,
                     result: @escaping FlutterResult) {
    // A measuring core still running would share the command socket path with
    // the extension; stop it first (its caller gets what it has so far).
    measure.cancel()
    // Write the config where the extension can read it (shared App Group).
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      result(FlutterError(code: "appgroup", message: "App Group not configured", details: nil))
      return
    }
    do {
      // Write any bundled rule-set files (e.g. geosite-ir.srs) into the shared
      // container, then point the config's placeholder paths at them.
      for (name, data) in ruleSets {
        try data.data.write(to: container.appendingPathComponent(name), options: .atomic)
      }
      let resolved = config.replacingOccurrences(
        of: Self.ruleSetBaseToken, with: container.path)
      try resolved.write(to: container.appendingPathComponent("config.json"),
                         atomically: true, encoding: .utf8)
      // The Xray config for an xhttp node, or remove a stale one so a normal
      // node never starts a leftover Xray in the extension.
      let xrayURL = container.appendingPathComponent("xray.json")
      if let xrayConfig, !xrayConfig.isEmpty {
        try xrayConfig.write(to: xrayURL, atomically: true, encoding: .utf8)
      } else if FileManager.default.fileExists(atPath: xrayURL.path) {
        try FileManager.default.removeItem(at: xrayURL)
      }
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
      // Auto-reconnect, and only when the user has asked for it.
      //
      // An on-demand "connect" rule brings the tunnel back if iOS terminates the
      // extension under memory pressure (a throughput burst can push the ~50MB
      // Network Extension over its limit). The cost is that the rule also
      // overrides the person using the phone: with it on, turning Nova off from
      // the iPhone's own Settings > VPN brought it straight back, so the only
      // way to stop it was inside the app, and switching to another VPN fought
      // with it. The OS switch has to win by default; Settings > Routing has
      // the opt-in for anyone who would rather have the safety net.
      if autoReconnect {
        let onDemand = NEOnDemandRuleConnect()
        onDemand.interfaceTypeMatch = .any
        mgr.onDemandRules = [onDemand]
        mgr.isOnDemandEnabled = true
      } else {
        mgr.onDemandRules = []
        mgr.isOnDemandEnabled = false
      }
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

  /// User-initiated Disconnect. On-demand is turned off (and saved) *before*
  /// stopping the tunnel so iOS won't immediately auto-reconnect the way it's
  /// designed to after an unexpected extension kill. Loads the manager first in
  /// case the app was relaunched while the tunnel kept running.
  private func stopTunnel(result: @escaping FlutterResult) {
    loadManagerIfNeeded { [weak self] in
      guard let self, let mgr = self.manager else { result(nil); return }
      mgr.isOnDemandEnabled = false
      mgr.onDemandRules = []
      mgr.saveToPreferences { _ in
        mgr.connection.stopVPNTunnel()
        result(nil)
      }
    }
  }

  /// Loads the already-configured tunnel manager into `self.manager` if we don't
  /// have a reference yet, so status queries after an app relaunch see the live
  /// connection instead of nil.
  private func loadManagerIfNeeded(_ completion: @escaping () -> Void) {
    if manager != nil { completion(); return }
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
      self?.manager = managers?.first
      completion()
    }
  }

  // MARK: - State stream

  @objc private func statusChanged() {
    let status = manager?.connection.status ?? .invalid
    emit(["type": "state", "value": stateName(status)])
    publishWidgetState(stateName(status))
    // Attach/detach the libbox status client so the dashboard gets live
    // download/upload throughput, not a frozen zero.
    switch status {
    case .connected:
      startStatusClient()
      startLogClient()
      startGroupClient()
    default:
      stopStatusClient()
      stopLogClient()
      stopGroupClient()
    }
  }

  // MARK: - Live traffic stats

  /// libbox's setup must run once in this process before a command client can
  /// find the extension's command socket. It points at the same shared App
  /// Group paths the extension uses.
  private func ensureNovacoreSetup() {
    if libboxReady { return }
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
    let setup = NovacoreSetupOptions()
    setup.basePath = container.path
    setup.workingPath = container.appendingPathComponent("work").path
    setup.tempPath = container.appendingPathComponent("tmp").path
    var err: NSError?
    NovacoreSetup(setup, &err)
    libboxReady = (err == nil)
  }

  /// Serializes the status-client lifecycle off the main thread. `NovacoreSetup`
  /// (in `ensureNovacoreSetup`) and the client connect are the heavy calls; running
  /// them here instead of on the platform/main thread is what stops the app from
  /// freezing for a beat when it's cold-launched (returned to) while the tunnel
  /// is already up. A serial queue also makes every `statusClient` mutation
  /// thread-safe.
  private let statusQueue = DispatchQueue(label: "tech.innovatenorth.novaedge.status")

  private func startStatusClient() {
    statusQueue.async { [weak self] in
      guard let self, self.statusClient == nil else { return }
      self.ensureNovacoreSetup()
      let options = NovacoreCommandClientOptions()
      // 1.13 replaced the single `command` field with a command list.
      options.addCommand(NovacoreCommandStatus)
      options.statusInterval = Int64(NSEC_PER_SEC) // one status push per second
      guard let client = NovacoreNewCommandClient(StatusHandler(host: self), options)
      else { return }
      self.statusClient = client
      // The extension's server may take a beat to bind after the tunnel reports
      // connected; retry a few times before giving up.
      self.connectStatusClientLocked(client, attempt: 0)
    }
  }

  /// Runs on `statusQueue`.
  private func connectStatusClientLocked(_ client: NovacoreCommandClient, attempt: Int) {
    do {
      try client.connect()
    } catch {
      guard statusClient === client, attempt < 5 else { return }
      statusQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self, self.statusClient === client else { return }
        self.connectStatusClientLocked(client, attempt: attempt + 1)
      }
    }
  }

  private func stopStatusClient() {
    statusQueue.async { [weak self] in
      guard let self, let client = self.statusClient else { return }
      self.statusClient = nil
      try? client.disconnect()
      self.emit(["type": "traffic", "up": 0, "down": 0, "upTotal": 0, "downTotal": 0])
    }
  }

  /// Attaches a second command client for the core's log stream, which backs
  /// Settings -> Logs. Separate from the status client on purpose: the status
  /// stream drives the dashboard's live speed meter and must not depend on the
  /// log subscription's lifecycle. How much this carries is decided by the
  /// config's `log.level`, which the Dart side raises to `info` only when the
  /// user turns on detailed logs.
  private func startLogClient() {
    statusQueue.async { [weak self] in
      guard let self, self.logClient == nil else { return }
      self.ensureNovacoreSetup()
      let options = NovacoreCommandClientOptions()
      options.addCommand(NovacoreCommandLog)
      guard let client = NovacoreNewCommandClient(LogHandler(host: self), options)
      else { return }
      self.logClient = client
      self.connectLogClientLocked(client, attempt: 0)
      self.startXrayLogTail()
    }
  }

  /// Polls the shared xray.log the NE writes and emits any new lines into the same
  /// `{type:"log"}` channel as sing-box's, tagged like Android ("[xray]", warn).
  /// Runs on `statusQueue`. The NE truncates the file on each connect, so a line
  /// count below what we've emitted means a fresh session — reset and re-read.
  private func startXrayLogTail() {
    guard xrayLogTimer == nil else { return }
    xrayLogSeen = 0
    guard let url = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
      .appendingPathComponent("xray.log") else { return }
    let timer = DispatchSource.makeTimerSource(queue: statusQueue)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
      var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      if lines.last == "" { lines.removeLast() }
      if lines.count < self.xrayLogSeen { self.xrayLogSeen = 0 } // new session
      guard lines.count > self.xrayLogSeen else { return }
      let fresh = lines[self.xrayLogSeen..<lines.count]
      self.xrayLogSeen = lines.count
      // level 3 == warn, so it survives the Dart quiet-log filter, same as Android.
      let batch = fresh.map { ["level": 3, "message": "[xray] \($0)"] as [String: Any] }
      self.emit(["type": "log", "lines": batch])
    }
    xrayLogTimer = timer
    timer.resume()
  }

  private func stopXrayLogTail() {
    xrayLogTimer?.cancel()
    xrayLogTimer = nil
    xrayLogSeen = 0
  }

  /// Runs on `statusQueue`.
  private func connectLogClientLocked(_ client: NovacoreCommandClient, attempt: Int) {
    do {
      try client.connect()
    } catch {
      guard logClient === client, attempt < 5 else { return }
      statusQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self, self.logClient === client else { return }
        self.connectLogClientLocked(client, attempt: attempt + 1)
      }
    }
  }

  private func stopLogClient() {
    statusQueue.async { [weak self] in
      guard let self else { return }
      self.stopXrayLogTail()
      guard let client = self.logClient else { return }
      self.logClient = nil
      try? client.disconnect()
    }
  }

  /// Attaches a third command client for the core's outbound-group stream: the
  /// auto-selector plus each pool node's urltest latency, measured through the
  /// running tunnel (so the SNI-block bypass is already applied). This is what
  /// lets the server list show a real ping, and which server is selected, for
  /// the clean-IP nodes that cannot be probed from outside the tunnel. Separate
  /// client for the same independent-lifecycle reason as the log one.
  private func startGroupClient() {
    statusQueue.async { [weak self] in
      guard let self, self.groupClient == nil else { return }
      self.ensureNovacoreSetup()
      let options = NovacoreCommandClientOptions()
      options.addCommand(NovacoreCommandGroup)
      options.statusInterval = Int64(NSEC_PER_SEC) * 3 // one group push per 3s
      guard let client = NovacoreNewCommandClient(GroupHandler(host: self), options)
      else { return }
      self.groupClient = client
      self.connectGroupClientLocked(client, attempt: 0)
    }
  }

  /// Runs on `statusQueue`.
  private func connectGroupClientLocked(_ client: NovacoreCommandClient, attempt: Int) {
    do {
      try client.connect()
      // Force the urltest so every pool node is measured now, instead of some
      // sitting unmeasured until the group's own 3-min interval (which is what
      // left nodes reading "not testable"). A few tries, because the router may
      // not be routing the instant the command socket accepts. Best-effort.
      for delay in [1.5, 4.0, 9.0] {
        statusQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
          guard let self, self.groupClient === client else { return }
          try? client.urlTest("proxy")
        }
      }
    } catch {
      guard groupClient === client, attempt < 5 else { return }
      statusQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self, self.groupClient === client else { return }
        self.connectGroupClientLocked(client, attempt: attempt + 1)
      }
    }
  }

  private func stopGroupClient() {
    statusQueue.async { [weak self] in
      guard let self, let client = self.groupClient else { return }
      self.groupClient = nil
      try? client.disconnect()
    }
  }

  /// Forwards a batch of core log lines. Batched because the core emits them in
  /// bursts and each event is a hop to the main thread.
  fileprivate func onLogs(_ list: NovacoreLogIteratorProtocol) {
    var batch: [[String: Any]] = []
    while list.hasNext() {
      guard let entry = list.next() else { continue }
      batch.append(["level": entry.level, "message": entry.message])
    }
    guard !batch.isEmpty else { return }
    emit(["type": "log", "lines": batch])
  }

  fileprivate func onStatus(_ message: NovacoreStatusMessage) {
    emit([
      "type": "traffic",
      "up": message.uplink,
      "down": message.downlink,
      "upTotal": message.uplinkTotal,
      "downTotal": message.downlinkTotal,
    ])
  }

  /// Flattens the core's outbound-group snapshot (auto-selector + per-node
  /// urltest delays) into plain dictionaries for the Dart side, which maps the
  /// `node-i` tags back to real servers.
  fileprivate func onGroups(_ iterator: NovacoreOutboundGroupIteratorProtocol) {
    var groups: [[String: Any]] = []
    while iterator.hasNext() {
      guard let group = iterator.next() else { continue }
      var items: [[String: Any]] = []
      if let itemIterator = group.getItems() {
        while itemIterator.hasNext() {
          guard let item = itemIterator.next() else { continue }
          // urlTestDelay is ms; 0 means no successful test yet.
          items.append(["tag": item.tag, "delay": item.urlTestDelay])
        }
      }
      groups.append([
        "tag": group.tag,
        "selected": group.selected,
        "items": items,
      ])
    }
    guard !groups.isEmpty else { return }
    emit(["type": "groups", "groups": groups])
  }

  private func stateName(_ s: NEVPNStatus) -> String {
    switch s {
    case .connected: return "connected"
    case .connecting, .reasserting: return "connecting"
    case .disconnecting: return "disconnecting"
    default: return "disconnected"
    }
  }

  // MARK: - Home-screen widget

  /// The active profile name, shown by the widget. Set on start; cosmetic.
  private var profileLabel: String?

  /// Mirror the tunnel state (and profile name) into the shared App Group so the
  /// WidgetKit extension can render it, then ask WidgetKit to refresh. The widget
  /// is a separate process, so this shared defaults store is how it learns the
  /// state; it never touches the tunnel itself.
  private func publishWidgetState(_ state: String) {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    defaults?.set(state, forKey: "nova.widget.state")
    defaults?.set(profileLabel, forKey: "nova.widget.label")
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
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

/// Receives the libbox status stream and forwards only the traffic numbers to
/// the host. Every other callback is a required-but-unused protocol stub.
private final class StatusHandler: NSObject, NovacoreCommandClientHandlerProtocol {
  private weak var host: NovaProxyHost?
  init(host: NovaProxyHost) { self.host = host }

  func writeStatus(_ message: NovacoreStatusMessage?) {
    guard let message else { return }
    host?.onStatus(message)
  }

  func connected() {}
  func disconnected(_ message: String?) {}
  func clearLogs() {}
  func initializeClashMode(_ modeList: NovacoreStringIteratorProtocol?, currentMode: String?) {}
  func updateClashMode(_ newMode: String?) {}
  func write(_ events: NovacoreConnectionEvents?) {}
  func writeGroups(_ message: NovacoreOutboundGroupIteratorProtocol?) {}
  func writeLogs(_ messageList: NovacoreLogIteratorProtocol?) {}
  // Added in sing-box 1.13's command-client handler; we drive log level from the
  // config, so this is a no-op.
  func setDefaultLogLevel(_ level: Int32) {}
}

/// Receives the libbox log stream and forwards it to the host. Every other
/// callback is a required-but-unused protocol stub.
private final class LogHandler: NSObject, NovacoreCommandClientHandlerProtocol {
  private weak var host: NovaProxyHost?
  init(host: NovaProxyHost) { self.host = host }

  func writeLogs(_ messageList: NovacoreLogIteratorProtocol?) {
    guard let messageList else { return }
    host?.onLogs(messageList)
  }

  func writeStatus(_ message: NovacoreStatusMessage?) {}
  func connected() {}
  func disconnected(_ message: String?) {}
  func clearLogs() {}
  func initializeClashMode(_ modeList: NovacoreStringIteratorProtocol?, currentMode: String?) {}
  func updateClashMode(_ newMode: String?) {}
  func write(_ events: NovacoreConnectionEvents?) {}
  func writeGroups(_ message: NovacoreOutboundGroupIteratorProtocol?) {}
  func setDefaultLogLevel(_ level: Int32) {}
}

/// Receives the libbox outbound-group stream and forwards the per-node urltest
/// snapshot to the host. Every other callback is a required-but-unused stub.
private final class GroupHandler: NSObject, NovacoreCommandClientHandlerProtocol {
  private weak var host: NovaProxyHost?
  init(host: NovaProxyHost) { self.host = host }

  func writeGroups(_ message: NovacoreOutboundGroupIteratorProtocol?) {
    guard let message else { return }
    host?.onGroups(message)
  }

  func writeStatus(_ message: NovacoreStatusMessage?) {}
  func writeLogs(_ messageList: NovacoreLogIteratorProtocol?) {}
  func connected() {}
  func disconnected(_ message: String?) {}
  func clearLogs() {}
  func initializeClashMode(_ modeList: NovacoreStringIteratorProtocol?, currentMode: String?) {}
  func updateClashMode(_ newMode: String?) {}
  func write(_ events: NovacoreConnectionEvents?) {}
  func setDefaultLogLevel(_ level: Int32) {}
}

// MARK: - Measuring core ("test all servers through the core")

/// The MEASURING core on iOS: a second core in THIS process (not the Network
/// Extension), so the extension's memory cap does not apply.
///
/// This class only owns the core's LIFETIME. The measuring itself is driven
/// from Dart over the core's Clash API (see MeasureRunner), one node at a time,
/// so every node gets its own timeout window and gets dialled twice: the first
/// dial pays whatever setup the protocol needs (a mieru session, a NaiveProxy
/// TLS + HTTP/2 connection) and only the second is reported. Letting sing-box's
/// urltest group sweep the pool instead is what used to report 400-800ms for
/// servers that answer in ~110ms.
///
/// The PlatformInterface is the extension's minus the TUN: openTun is never
/// called without a tun inbound, sockets bind to the real default interface via
/// the same NWPathMonitor scheme the extension uses.
final class NovaMeasure: NSObject {
  static let appGroup = NovaProxyHost.appGroup

  private let queue = DispatchQueue(label: "tech.innovatenorth.novaedge.measure")
  private var server: NovacoreCommandServer?
  private var xrayStarted = false
  private var pathMonitor: NWPathMonitor?
  private var runId = 0

  /// Starts the measuring core and calls [ready] once its service is up, or
  /// [fail] with a reason. The caller then drives the run over the core's Clash
  /// API and calls `cancel()` when it is done.
  func start(config: String, xrayConfig: String?,
             ready: @escaping () -> Void,
             fail: @escaping (String) -> Void) {
    runId += 1
    let id = runId
    queue.async { [self] in
      var answered = false
      func answer(_ error: String?) {
        if answered { return }
        answered = true
        if error != nil { stopLocked() }
        DispatchQueue.main.async {
          if let error { fail(error) } else { ready() }
        }
      }
      stopLocked()
      guard let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
        return answer("App Group not configured")
      }
      // libbox's command server normally listens on a unix socket inside the
      // base path; the App Group container path can exceed the 104-byte
      // sun_path limit (it does on the Simulator: "bind: invalid argument"),
      // and sharing the extension's socket path is wrong anyway. For the
      // duration of the run, point libbox at a loopback TCP port instead;
      // Setup is plain global assignment and the tunnel is down while this
      // runs, so nothing else is using the socket. Restored in stopLocked.
      Self.applySetup(container: container, port: Self.commandPort)

      // xhttp nodes in the pool run on the Xray core; the measuring core
      // reaches them as local socks exits. Start Xray first.
      if let xrayConfig, !xrayConfig.isEmpty {
        let xerr = NovaxrayStart(xrayConfig)
        if !xerr.isEmpty { return answer("Xray failed to start: \(xerr)") }
        xrayStarted = true
      }

      var err: NSError?
      guard let s = NovacoreNewCommandServer(MeasureServerHandler(), self, &err), err == nil else {
        return answer(err?.localizedDescription ?? "could not create the measuring core")
      }
      do {
        try s.start()
        server = s
        try s.startOrReloadService(config, options: NovacoreOverrideOptions())
      } catch {
        return answer("Could not start the measuring core: \(error.localizedDescription)")
      }
      if id != runId { return answer("cancelled") }
      answer(nil)
    }
  }

  /// Stops the measuring core. Safe to call when nothing is running.
  func cancel() {
    runId += 1
    queue.async { [self] in stopLocked() }
  }

  /// Runs on `queue`.
  private func stopLocked() {
    if let s = server {
      try? s.closeService()
      s.close()
    }
    server = nil
    if xrayStarted {
      xrayStarted = false
      NovaxrayStop()
    }
    pathMonitor?.cancel()
    pathMonitor = nil
    // Back to the unix-socket mode the extension's status/log/group clients
    // need.
    if let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) {
      Self.applySetup(container: container, port: 0)
    }
  }

  /// Loopback TCP port for the measuring run's command server.
  private static let commandPort: Int32 = 17893

  static func applySetup(container: URL, port: Int32) {
    let setup = NovacoreSetupOptions()
    setup.basePath = container.path
    setup.workingPath = container.appendingPathComponent("work").path
    setup.tempPath = container.appendingPathComponent("tmp").path
    setup.commandServerListenPort = port
    var err: NSError?
    NovacoreSetup(setup, &err)
  }
}

private final class MeasureServerHandler: NSObject, NovacoreCommandServerHandlerProtocol {
  func getSystemProxyStatus() throws -> NovacoreSystemProxyStatus {
    let s = NovacoreSystemProxyStatus()
    s.available = false
    s.enabled = false
    return s
  }
  func serviceStop() throws {}
  func serviceReload() throws {}
  func setSystemProxyEnabled(_ enabled: Bool) throws {}
  func writeDebugMessage(_ message: String?) {}
}

extension NovaMeasure: NovacorePlatformInterfaceProtocol {
  func openTun(_ options: NovacoreTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    throw NSError(domain: "Nova", code: 7, userInfo: [NSLocalizedDescriptionKey: "the measuring core has no TUN"])
  }
  func localDNSTransport() -> NovacoreLocalDNSTransportProtocol? { nil }
  func systemCertificates() -> NovacoreStringIteratorProtocol? { nil }
  func useProcFS() -> Bool { false }
  func underNetworkExtension() -> Bool { false }
  func includeAllNetworks() -> Bool { false }
  func usePlatformAutoDetectControl() -> Bool { false }
  func autoDetectControl(_: Int32) throws {}
  func clearDNSCache() {}

  func startDefaultInterfaceMonitor(_ listener: NovacoreInterfaceUpdateListenerProtocol?) throws {
    guard let listener else { return }
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    let semaphore = DispatchSemaphore(value: 0)
    monitor.pathUpdateHandler = { path in
      self.report(listener, path)
      semaphore.signal()
      monitor.pathUpdateHandler = { path in self.report(listener, path) }
    }
    monitor.start(queue: DispatchQueue.global())
    _ = semaphore.wait(timeout: .now() + 3)
  }

  private func report(_ listener: NovacoreInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
    guard path.status != .unsatisfied, let iface = path.availableInterfaces.first else {
      listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
      return
    }
    listener.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index),
                                    isExpensive: path.isExpensive, isConstrained: path.isConstrained)
  }

  func closeDefaultInterfaceMonitor(_: NovacoreInterfaceUpdateListenerProtocol?) throws {
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  func getInterfaces() throws -> NovacoreNetworkInterfaceIteratorProtocol {
    guard let path = pathMonitor?.currentPath, path.status != .unsatisfied else {
      return MeasureInterfaceArray([])
    }
    var out: [NovacoreNetworkInterface] = []
    for it in path.availableInterfaces {
      let n = NovacoreNetworkInterface()
      n.name = it.name
      n.index = Int32(it.index)
      switch it.type {
      case .wifi: n.type = NovacoreInterfaceTypeWIFI
      case .cellular: n.type = NovacoreInterfaceTypeCellular
      case .wiredEthernet: n.type = NovacoreInterfaceTypeEthernet
      default: n.type = NovacoreInterfaceTypeOther
      }
      out.append(n)
    }
    return MeasureInterfaceArray(out)
  }

  func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                           destinationAddress _: String?, destinationPort _: Int32) throws -> NovacoreConnectionOwner {
    throw NSError(domain: "Nova", code: 6, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
  }
  func readWIFIState() -> NovacoreWIFIState? { nil }
  func send(_: NovacoreNotification?) throws {}
}

private final class MeasureInterfaceArray: NSObject, NovacoreNetworkInterfaceIteratorProtocol {
  private var iterator: IndexingIterator<[NovacoreNetworkInterface]>
  private var current: NovacoreNetworkInterface?
  init(_ array: [NovacoreNetworkInterface]) { iterator = array.makeIterator() }
  func hasNext() -> Bool {
    current = iterator.next()
    return current != nil
  }
  func next() -> NovacoreNetworkInterface? { current }
}
