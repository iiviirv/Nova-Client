import Cocoa
import FlutterMacOS
import NetworkExtension
import SystemExtensions

/// The Mac app's side of the Network Extension: activate it once, then start and
/// stop the tunnel through the VPN configuration macOS keeps for us.
///
/// What this replaces is worth stating plainly. Whole-device mode used to run
/// the core through an AppleScript administrator prompt, so the Mac asked for a
/// password on every single connect, and Nova appeared nowhere in System
/// Settings. A system extension is approved once and then started by macOS with
/// the privileges it needs, and the VPN configuration is what puts "Nova" in the
/// Network pane beside Wi-Fi.
///
/// Deliberately small. The extension runs the same config the desktop core ran,
/// including its Clash API on loopback, so everything the app already does with
/// that (traffic, latency, health, the server board) keeps working untouched.
/// This channel only has to answer four questions: is the extension installed,
/// install it, start this config, stop.
final class NovaTunnelHost: NSObject {
  static let extensionBundleId = "online.novaproxy.novaClient.NovaTunnel"
  static let appGroup = "A53J987N2C.group.online.novaproxy.novaClient"
  private static let vpnDescription = "Nova"

  private var manager: NETunnelProviderManager?
  private var activation: ActivationDelegate?

  static func register(with registrar: FlutterPluginRegistrar) {
    let host = NovaTunnelHost()
    let channel = FlutterMethodChannel(name: "nova.tun/control",
                                       binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler(host.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      // Whether this build can use the extension at all. False on a build that
      // was not signed with the entitlement, which is every local debug build,
      // and the caller falls back to the old elevated core.
      result(Bundle.main.object(forInfoDictionaryKey: "NovaTunnelExtension") as? Bool ?? true)

    case "activate":
      activate(result)

    case "reinstall":
      // Deactivate first, then install again.
      //
      // macOS will not swap a running system extension for a rebuilt one on
      // its own: it keeps the copy it has and answers "will complete after
      // reboot", so a fix ships and the machine goes on running the old code.
      // Taking it out first is the only way to get the new one in without
      // asking someone to restart their Mac.
      let delegate = ActivationDelegate(done: { [weak self] _ in
        self?.activation = nil
        self?.activate(result)
      })
      activation = delegate
      let request = OSSystemExtensionRequest.deactivationRequest(
        forExtensionWithIdentifier: Self.extensionBundleId, queue: .main)
      request.delegate = delegate
      OSSystemExtensionManager.shared.submitRequest(request)

    case "start":
      guard let args = call.arguments as? [String: Any],
            let config = args["configJson"] as? String else {
        result(FlutterError(code: "args", message: "configJson required", details: nil))
        return
      }
      start(config: config, xray: args["xrayConfigJson"] as? String, result: result)

    case "stop":
      stop(result)

    case "status":
      loadManager { mgr in
        result(Self.name(for: mgr?.connection.status ?? .invalid))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - The extension itself

  /// Asks macOS to activate the system extension, which is what shows the user
  /// the one approval they will ever be asked for. Already-approved is success,
  /// not an error: macOS answers "request superseded" or completes immediately.
  private func activate(_ result: @escaping FlutterResult) {
    let delegate = ActivationDelegate(done: { [weak self] outcome in
      self?.activation = nil
      switch outcome {
      case .completed: result("completed")
      case .needsApproval: result("needsApproval")
      case .needsReboot: result("needsReboot")
      case let .failed(message): result(FlutterError(code: "activate", message: message, details: nil))
      }
    })
    activation = delegate
    // What the app can actually see of itself, logged before asking. macOS
    // answers "extension not found in app bundle" for several unrelated
    // reasons, and this is the difference between reading that message and
    // knowing which one it was.
    let dir = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/SystemExtensions")
    let found = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
      .joined(separator: ", ") ?? "nothing"
    NSLog("Nova: bundle at %@; system extensions: [%@]",
          Bundle.main.bundleURL.path, found)
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: Self.extensionBundleId, queue: .main)
    request.delegate = delegate
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  // MARK: - The tunnel

  private func start(config: String, xray: String?, result: @escaping FlutterResult) {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      result(FlutterError(code: "group", message: "App Group container missing", details: nil))
      return
    }
    let rewritten: String
    do {
      // Rule-set files still cross through the shared container: the core reads
      // them by path, and root can read the user's copy.
      rewritten = try Self.rehomeRuleSets(config, into: container)
      // Also written to the container, for a provider old enough to look there.
      try? rewritten.write(to: container.appendingPathComponent("config.json"),
                           atomically: true, encoding: .utf8)
      let xrayURL = container.appendingPathComponent("xray.json")
      if let xray, !xray.isEmpty {
        try xray.write(to: xrayURL, atomically: true, encoding: .utf8)
      } else if FileManager.default.fileExists(atPath: xrayURL.path) {
        // A stale Xray config would start a second core the new node does not
        // want, so it goes rather than lingering.
        try? FileManager.default.removeItem(at: xrayURL)
      }
    } catch {
      result(FlutterError(code: "write", message: error.localizedDescription, details: nil))
      return
    }

    loadManager { [weak self] existing in
      guard let self else { return }
      let mgr = existing ?? NETunnelProviderManager()
      let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
        ?? NETunnelProviderProtocol()
      proto.providerBundleIdentifier = Self.extensionBundleId
      // The config travels in the configuration itself, not through the shared
      // container.
      //
      // A system extension runs as root, and root's App Group container is
      // /private/var/root/Library/Group Containers/..., a different directory
      // from the one the app writes to in the user's home. The provider read
      // its own empty container, threw "no such file", and the tunnel went
      // straight back to disconnected with the reason buried in the VPN
      // session's last-disconnect error where nothing surfaces it.
      var provider: [String: Any] = ["config": rewritten]
      if let xray, !xray.isEmpty { provider["xray"] = xray }
      proto.providerConfiguration = provider
      // Shown as the server address in the Network pane. There is no single
      // server (a subscription is a list), so it says what it is.
      proto.serverAddress = "Nova"
      mgr.protocolConfiguration = proto
      mgr.localizedDescription = Self.vpnDescription
      mgr.isEnabled = true
      mgr.saveToPreferences { error in
        if let error {
          result(FlutterError(code: "save", message: error.localizedDescription, details: nil))
          return
        }
        // Reload before starting: a manager that was just saved has a stale
        // connection object, and starting it throws.
        mgr.loadFromPreferences { _ in
          do {
            try mgr.connection.startVPNTunnel()
            self.manager = mgr
            result(true)
          } catch {
            result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  /// Copies the config's local rule-set files into the shared container and
  /// points the config at them there.
  ///
  /// The config is built for a core that runs as the user, so its rule-set
  /// paths are inside the app's own Application Support. The extension is a
  /// different process with a different container and cannot read them, and a
  /// rule-set sing-box cannot open is fatal: the tunnel starts and immediately
  /// stops, which reads as "the tunnel did not come up" with nothing else to go
  /// on. Anything the extension has to read has to live in the container both
  /// sides share.
  static func rehomeRuleSets(_ config: String, into container: URL) throws -> String {
    guard let data = config.data(using: .utf8),
          var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var route = root["route"] as? [String: Any],
          var sets = route["rule_set"] as? [[String: Any]], !sets.isEmpty
    else { return config }

    let fm = FileManager.default
    let dir = container.appendingPathComponent("rule-sets")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

    for i in sets.indices {
      guard let path = sets[i]["path"] as? String, !path.isEmpty else { continue }
      let source = URL(fileURLWithPath: path)
      let destination = dir.appendingPathComponent(source.lastPathComponent)
      if fm.fileExists(atPath: source.path) {
        // Copy every time: a Nova update ships new rule sets, and a stale one
        // here would outlive it silently.
        try? fm.removeItem(at: destination)
        try? fm.copyItem(at: source, to: destination)
      }
      guard fm.fileExists(atPath: destination.path) else { continue }
      sets[i]["path"] = destination.path
    }
    route["rule_set"] = sets
    root["route"] = route
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    return String(data: out, encoding: .utf8) ?? config
  }

  private func stop(_ result: @escaping FlutterResult) {
    loadManager { mgr in
      mgr?.connection.stopVPNTunnel()
      result(true)
    }
  }

  private func loadManager(_ done: @escaping (NETunnelProviderManager?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      let mine = managers?.first { m in
        (m.protocolConfiguration as? NETunnelProviderProtocol)?
          .providerBundleIdentifier == Self.extensionBundleId
      }
      self.manager = mine ?? managers?.first
      done(self.manager)
    }
  }

  private static func name(for status: NEVPNStatus) -> String {
    switch status {
    case .connected: return "connected"
    case .connecting, .reasserting: return "connecting"
    case .disconnecting: return "disconnecting"
    case .disconnected: return "disconnected"
    default: return "invalid"
    }
  }
}

/// One-shot delegate for an activation or deactivation request.
///
/// "Needs approval" is the normal first answer to a first install: macOS shows
/// the user a prompt in System Settings and tells us to wait, so it is its own
/// outcome rather than a failure, and the app can say what to click.
///
/// Every other answer is reported verbatim rather than flattened. macOS has
/// several ways of saying "not now" that look identical from the app and mean
/// completely different things, and guessing between them cost a day: an
/// extension that is already installed at an older build answers
/// `willCompleteAfterReboot` and keeps running the copy it has.
private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
  enum Outcome {
    case completed
    case needsApproval
    case needsReboot
    case failed(String)
  }

  private let done: (Outcome) -> Void
  private var answered = false

  init(done: @escaping (Outcome) -> Void) { self.done = done }

  private func answer(_ outcome: Outcome) {
    guard !answered else { return }
    answered = true
    done(outcome)
  }

  func request(_: OSSystemExtensionRequest,
               actionForReplacingExtension existing: OSSystemExtensionProperties,
               withExtension replacement: OSSystemExtensionProperties)
    -> OSSystemExtensionRequest.ReplacementAction {
    // Always take the one shipped in this app bundle: a Nova update carries a
    // new extension, and refusing the replacement would leave the old core
    // running the new app's config.
    _ = existing
    _ = replacement
    return .replace
  }

  func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
    answer(.needsApproval)
  }

  func request(_: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    switch result {
    case .completed:
      answer(.completed)
    case .willCompleteAfterReboot:
      answer(.needsReboot)
    @unknown default:
      answer(.needsApproval)
    }
  }

  func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
    answer(.failed(error.localizedDescription))
  }
}
