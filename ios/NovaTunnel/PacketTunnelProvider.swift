import Foundation
// The Rust WARP core, linked as a static library. Its module map comes from
// Aether.xcframework; see ios/IOS_BUILD.md for where that is built.
import Aether
import Novacore
import Network
import NetworkExtension
import UserNotifications
// sing-box 1.13's libbox references UIKit (UIApplication background-task APIs)
// that 1.12 did not. The extension's own Swift never touches UIKit, but importing
// it here auto-links UIKit.framework so the libbox symbols resolve at link time.
import UIKit

/// The sing-box Network Extension for iOS. Reads the config the app wrote to the
/// shared App Group, sets up the TUN from sing-box's requested options, and runs
/// the core. The provider is the libbox PlatformInterface (TUN + interface
/// monitor), mirroring the Android VpnService host.
///
/// openTun and the interface monitor are adapted from sing-box-for-apple's
/// ExtensionPlatformInterface; if you hit routing edge cases, cross-check against
/// that reference (it is built against this same Novacore.xcframework).
class PacketTunnelProvider: NEPacketTunnelProvider {
  static let appGroup = "group.tech.innovatenorth.novaedge"

  private var commandServer: NovacoreCommandServer?
  private var xrayStarted = false

  /// True while the MasterDNS engine is running in this process.
  private var masterDnsStarted = false
  /// The Aether tunnel's job id, or nil when this connection has no WARP core.
  private var aetherJob: UInt64?

  /// What the WARP tunnel was started with, so it can be started again.
  ///
  /// The core can stop serving while the extension still believes it is
  /// connected, and that is worse than a disconnect: the tunnel device stays
  /// up, so every packet on the phone is routed into a tunnel that carries
  /// nothing and the device loses the internet entirely until Nova is switched
  /// off. Waking from sleep is the reliable way to reproduce it, because the
  /// socket the core holds belongs to a network that no longer exists.
  private var aetherSpec: (identity: [String: Any], tunnel: Any, port: UInt16)?
  private var aetherTimer: DispatchSourceTimer?
  private var aetherFailures = 0
  private var aetherNextAttempt = Date.distantPast
  private var aetherBusy = false
  private let aetherQueue = DispatchQueue(label: "online.novaproxy.aether.watch")
  private var xrayLogSink: XrayLogSink?
  private var pathMonitor: NWPathMonitor?

  override func startTunnel(options _: [String: NSObject]?) async throws {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      throw NSError(domain: "Nova", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group missing"])
    }
    let base = container.path
    let setup = NovacoreSetupOptions()
    setup.basePath = base
    setup.workingPath = container.appendingPathComponent("work").path
    setup.tempPath = container.appendingPathComponent("tmp").path
    try? FileManager.default.createDirectory(atPath: setup.workingPath, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: setup.tempPath, withIntermediateDirectories: true)
    var setupErr: NSError?
    NovacoreSetup(setup, &setupErr)

    let config = try String(contentsOf: container.appendingPathComponent("config.json"), encoding: .utf8)

    // xhttp node: start the Xray core first (from xray.json) so its local SOCKS
    // inbound is up before sing-box bridges the TUN to it. On iOS the extension's
    // own sockets bypass its tunnel, so no socket protector is needed here (unlike
    // Android's VpnService). Xray and sing-box share this one Novacore framework.
    let xrayURL = container.appendingPathComponent("xray.json")
    if let xrayCfg = try? String(contentsOf: xrayURL, encoding: .utf8),
       !xrayCfg.isEmpty {
      // Bridge Xray's own log to the app. The NE is a separate process, so it
      // can't push to the Flutter engine the way Android's in-process VpnService
      // does; instead the sink writes to a shared App Group file that the app
      // tails into the Core log (see NovaProxyHost). Start each connection with a
      // fresh file so the app's tail offset lines up.
      let logURL = container.appendingPathComponent("xray.log")
      try? Data().write(to: logURL)
      xrayLogSink = XrayLogSink(url: logURL)
      NovaxraySetLogger(xrayLogSink)
      let xerr = NovaxrayStart(xrayCfg)
      if !xerr.isEmpty {
        throw NSError(domain: "Nova", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Xray: \(xerr)"])
      }
      xrayStarted = true
    }

    // WARP node: open the Aether tunnel before sing-box, so the local SOCKS it
    // forwards into is already serving. Same shape as the Xray block above, and
    // for the same reason.
    //
    // Unlike Android, order is all this needs: the extension's own sockets
    // bypass its tunnel, so the core's dial to Cloudflare is never captured and
    // fed back into the chain it is supposed to be providing.
    //
    // The core lives here rather than in the app because the app is suspended
    // when the user leaves it, and a tunnel hosted there would go with it.
    try startAetherIfConfigured(container: container)
    // MasterDNS node: start the engine before sing-box, and only carry on once
    // its port answers, which it does once it has a working path through the
    // resolvers. A tunnel brought up before that would carry nothing.
    try startMasterDnsIfConfigured(container: container)

    // sing-box 1.13 folded the box service into the command server: instead of
    // NovacoreNewService(config, platform) + a separate command server, the command
    // server now takes the PlatformInterface (self) and owns the service. We
    // create it, start its App Group control socket (so the main app can attach a
    // status client for live traffic), then start the service from the config,
    // which is what dials the TUN via openTun below.
    var err: NSError?
    guard let server = NovacoreNewCommandServer(commandServerHandler, self, &err), err == nil else {
      throw err ?? NSError(domain: "Nova", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create command server"])
    }
    try server.start()
    // Pass a real (empty) options object, NOT nil: despite the ObjC param being
    // marked nullable, libbox 1.13's StartOrReloadService dereferences it
    // (options.AutoRedirect) with no nil check, so nil panics the extension and
    // the tunnel never comes up.
    try server.startOrReloadService(config, options: NovacoreOverrideOptions())
    commandServer = server

    // Proxy mode: the config has a loopback `mixed` inbound and no `tun`, so
    // openTun is never called and nothing ever applies tunnel settings. iOS
    // still expects a Packet Tunnel Provider to have some, so apply a set that
    // captures nothing: the phone keeps routing its own traffic and only an app
    // pointed at 127.0.0.1 goes through Nova. (A Network Extension is still the
    // host, because it is the only way a listener survives the app going to the
    // background; the difference is what it does with packets, not that it
    // exists.)
    if !config.contains("\"type\": \"tun\"") && !config.contains("\"type\":\"tun\"") {
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
      let v4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
      v4.includedRoutes = []
      v4.excludedRoutes = [NEIPv4Route.default()]
      settings.ipv4Settings = v4
      try await setTunnelNetworkSettings(settings)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    pathMonitor?.cancel()
    pathMonitor = nil
    try? commandServer?.closeService()
    try? commandServer?.close()
    commandServer = nil
    if masterDnsStarted {
      masterDnsStarted = false
      // The engine never stops on its own, even with nothing to reach.
      NovamasterdnsStop()
    }
    if xrayStarted {
      xrayStarted = false
      NovaxraySetLogger(nil)
      _ = NovaxrayStop()
    }
    xrayLogSink = nil
    stopAetherWatchdog()
    if let job = aetherJob {
      aetherJob = nil
      // Frees the job and closes the SOCKS port with it. Left running, the next
      // connection would find the port taken and pick a different one while the
      // config it was written against still names this one.
      if let raw = aether_job_cancel(job) { aether_string_free(raw) }
    }
    notifyIfUnexpected(reason)
  }

  // MARK: - MasterDNS

  /// Starts the MasterDNS engine from `masterdns.json`, when this connection
  /// has one.
  ///
  /// The engine is compiled into Novacore rather than run as a process: iOS
  /// allows no second process, and this extension already holds sing-box's Go
  /// runtime, so the engine has to share it.
  ///
  /// The file carries the encryption key, so it is removed as soon as it has
  /// been read. Resolvers go to a file of their own because the engine cannot
  /// read them from its JSON.
  private func startMasterDnsIfConfigured(container: URL) throws {
    let url = container.appendingPathComponent("masterdns.json")
    guard let raw = try? Data(contentsOf: url) else { return }
    try? FileManager.default.removeItem(at: url)
    guard let env = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let engine = env["config"] as? String,
          let resolvers = env["resolvers"] as? String,
          let portNumber = env["port"] as? NSNumber else {
      throw masterDnsError("its settings could not be read")
    }
    let resolversURL = container.appendingPathComponent("masterdns-resolvers.txt")
    try resolvers.write(to: resolversURL, atomically: true, encoding: .utf8)
    // The engine's own log, since this extension's output goes nowhere. It is
    // what explains a tunnel that never formed.
    let logURL = container.appendingPathComponent("masterdns.log")
    try? FileManager.default.removeItem(at: logURL)

    var failure: NSError?
    if !NovamasterdnsStart(engine, resolversURL.path, logURL.path, &failure) {
      throw masterDnsError(failure?.localizedDescription ?? "the engine did not start")
    }
    masterDnsStarted = true

    let port = portNumber.uint16Value
    let deadline = Date().addingTimeInterval(40)
    while Date() < deadline {
      if aetherPortAccepts(port) { return }
      Thread.sleep(forTimeInterval: 0.3)
    }
    masterDnsStarted = false
    NovamasterdnsStop()
    throw masterDnsError(
      "could not reach its server through any of the resolvers. The domain may "
        + "be wrong, or these resolvers may be filtered on this network.")
  }

  private func masterDnsError(_ message: String) -> NSError {
    NSError(domain: "Nova", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "MasterDNS: \(message)"])
  }

  // MARK: - Aether (WARP)

  /// Opens the WARP tunnel this connection forwards into, if there is one.
  ///
  /// `aether.json` is written by the app next to `config.json`, and carries the
  /// tunnel payload verbatim plus the transport. The identity half is built
  /// here because it names a path, and only this process knows its own
  /// container.
  ///
  /// Every call into the core returns a malloc'd JSON string that has to be
  /// freed, and every one of them can report failure inside a reply that is
  /// itself successful, so both layers are checked.
  private func startAetherIfConfigured(container: URL) throws {
    let url = container.appendingPathComponent("aether.json")
    guard let raw = try? Data(contentsOf: url),
          let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let transport = envelope["transport"] as? String,
          let tunnel = envelope["tunnel"] else { return }

    // The identity is per transport and is kept in the shared container, so a
    // registration survives a reconnect instead of being made again each time.
    let identityPayload: [String: Any] = [
      "path": container.appendingPathComponent("aether").path,
      "transport": transport,
    ]
    let identity = try aetherJob(
      call: { aether_identity_open($0) },
      payload: identityPayload,
      what: "open the WARP identity")
    guard let handle = (identity["identity"] as? NSNumber)?.uint64Value else {
      throw aetherError("the core returned no identity handle")
    }

    let started = try aetherCall(
      { aether_tunnel_start(handle, $0) },
      payload: tunnel,
      what: "start the WARP tunnel")
    guard let job = (started["job"] as? NSNumber)?.uint64Value else {
      throw aetherError("the core started no job for the tunnel")
    }
    aetherJob = job

    // A tunnel job stays running for as long as the tunnel is up, so there is
    // nothing to wait for it to finish. What matters is that it has not already
    // failed, and that the port answers before sing-box is pointed at it.
    let now = try aetherPoll(job)
    if (now["state"] as? String) == "failed" {
      throw aetherError((now["error"] as? String) ?? "the tunnel failed on startup")
    }
    guard let socks = (tunnel as? [String: Any])?["socks"] as? String,
          let port = UInt16(socks.split(separator: ":").last.map(String.init) ?? "") else {
      throw aetherError("the tunnel payload named no port to wait on")
    }
    try awaitAetherPort(port)
    aetherSpec = (identity: identityPayload, tunnel: tunnel, port: port)
    armAetherWatchdog()
  }

  // MARK: - Keeping the WARP tunnel alive

  /// Checks the live tunnel every so often and brings it back when it dies.
  ///
  /// Fifteen seconds is a compromise: the failure takes the whole phone
  /// offline, so noticing late is expensive, but each check opens a loopback
  /// connection and doing that every second for the life of a connection is
  /// not free either.
  private func armAetherWatchdog() {
    aetherTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: aetherQueue)
    timer.schedule(deadline: .now() + 15, repeating: 15)
    timer.setEventHandler { [weak self] in self?.checkAether() }
    timer.resume()
    aetherTimer = timer
  }

  private func stopAetherWatchdog() {
    aetherTimer?.cancel()
    aetherTimer = nil
    aetherSpec = nil
    aetherFailures = 0
    aetherNextAttempt = .distantPast
  }

  /// One pass. Overlapping calls do nothing, so a slow restart cannot have a
  /// second one started on top of it.
  private func checkAether() {
    guard !aetherBusy, let spec = aetherSpec else { return }
    aetherBusy = true
    defer { aetherBusy = false }

    if aetherIsServing(port: spec.port) {
      if aetherFailures > 0 {
        NSLog("Nova: the WARP tunnel is carrying traffic again")
      }
      aetherFailures = 0
      aetherNextAttempt = .distantPast
      return
    }
    // Backoff, because the usual cause is a network that is not there yet. A
    // phone coming out of sleep has no route for a moment, and each attempt
    // opens an identity and dials a gateway.
    if Date() < aetherNextAttempt { return }
    aetherFailures += 1
    NSLog("Nova: the WARP tunnel stopped carrying traffic, so nothing on this "
      + "device could reach the internet. Restarting it (attempt \(aetherFailures))")
    restartAether(spec)
    let backoff = min(5.0 * pow(2.0, Double(aetherFailures - 1)), 60.0)
    aetherNextAttempt = Date().addingTimeInterval(backoff)
  }

  /// Two questions, because they fail separately: the core can report its job
  /// as failed, and it can also quietly stop accepting on the port sing-box
  /// forwards into while the job still looks alive.
  private func aetherIsServing(port: UInt16) -> Bool {
    if let job = aetherJob {
      if let now = try? aetherPoll(job), (now["state"] as? String) == "failed" {
        return false
      }
    }
    return aetherPortAccepts(port)
  }

  private func restartAether(_ spec: (identity: [String: Any], tunnel: Any, port: UInt16)) {
    if let job = aetherJob {
      aetherJob = nil
      if let raw = aether_job_cancel(job) { aether_string_free(raw) }
    }
    do {
      let identity = try aetherJob(
        call: { aether_identity_open($0) },
        payload: spec.identity,
        what: "reopen the WARP identity")
      guard let handle = (identity["identity"] as? NSNumber)?.uint64Value else {
        throw aetherError("the core returned no identity handle")
      }
      // The same port on purpose: sing-box is already forwarding into it and
      // has no idea any of this happened.
      let started = try aetherCall(
        { aether_tunnel_start(handle, $0) },
        payload: spec.tunnel,
        what: "restart the WARP tunnel")
      guard let job = (started["job"] as? NSNumber)?.uint64Value else {
        throw aetherError("the core started no job for the tunnel")
      }
      aetherJob = job
      try awaitAetherPort(spec.port)
      NSLog("Nova: the WARP tunnel was restarted on port \(spec.port)")
    } catch {
      NSLog("Nova: could not restart the WARP tunnel: \(error.localizedDescription)")
    }
  }

  /// One call into the core, with its reply parsed and its string freed.
  private func aetherCall(_ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
                          payload: Any,
                          what: String) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let json = String(data: data, encoding: .utf8) else {
      throw aetherError("could not encode the payload to \(what)")
    }
    guard let out = json.withCString({ fn($0) }) else {
      throw aetherError("the core returned nothing when asked to \(what)")
    }
    defer { aether_string_free(out) }
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))
            as? [String: Any] else {
      throw aetherError("the core returned something that is not JSON")
    }
    if (parsed["ok"] as? Bool) != true {
      throw aetherError((parsed["error"] as? String) ?? "could not \(what)")
    }
    return parsed
  }

  /// A call that returns a job id, polled until it finishes.
  ///
  /// Opening an identity talks to Cloudflare on a first run, so this can take
  /// seconds. Treating it as immediate gets a job number where a handle was
  /// expected and every later call then fails with "there is no identity".
  private func aetherJob(call: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
                         payload: Any,
                         what: String) throws -> [String: Any] {
    let started = try aetherCall(call, payload: payload, what: what)
    guard let job = (started["job"] as? NSNumber)?.uint64Value else {
      throw aetherError("the core started no job to \(what)")
    }
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      let st = try aetherPoll(job)
      switch st["state"] as? String {
      case "running": Thread.sleep(forTimeInterval: 0.25)
      case "failed": throw aetherError((st["error"] as? String) ?? "could not \(what)")
      default:
        // The result is itself an envelope: a poll can succeed while the work
        // inside it failed, so the inner ok is the one that matters.
        guard let inner = st["result"] as? [String: Any] else {
          throw aetherError("the job finished without saying what happened")
        }
        if (inner["ok"] as? Bool) != true {
          throw aetherError((inner["error"] as? String) ?? "could not \(what)")
        }
        return inner
      }
    }
    if let raw = aether_job_cancel(job) { aether_string_free(raw) }
    throw aetherError("the core did not answer in time when asked to \(what)")
  }

  private func aetherPoll(_ job: UInt64) throws -> [String: Any] {
    guard let out = aether_job_poll(job) else {
      throw aetherError("the core returned nothing for a job poll")
    }
    defer { aether_string_free(out) }
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))
            as? [String: Any] else {
      throw aetherError("the core returned a job status that is not JSON")
    }
    if (parsed["ok"] as? Bool) != true {
      throw aetherError((parsed["error"] as? String) ?? "the job poll failed")
    }
    return parsed
  }

  /// Waits for the SOCKS port to accept a connection.
  ///
  /// Without it sing-box is pointed at a port nothing is listening on yet, and
  /// the first requests fail for no reason the user can see.
  private func awaitAetherPort(_ port: UInt16) throws {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      if aetherPortAccepts(port) { return }
      Thread.sleep(forTimeInterval: 0.2)
    }
    throw aetherError("the WARP tunnel never started serving on \(port)")
  }

  /// Whether anything is accepting on the loopback port sing-box forwards into.
  private func aetherPortAccepts(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  /// The system telling us the device woke up.
  ///
  /// This is the moment the core is most likely to be holding a socket for a
  /// network that no longer exists, and the moment a stale backoff is most
  /// pointless: the user has just picked the phone up and is looking at a
  /// connection that carries nothing.
  override func wake() {
    aetherNextAttempt = .distantPast
    aetherQueue.async { [weak self] in self?.checkAether() }
  }

  private func aetherError(_ message: String) -> NSError {
    NSError(domain: "Nova", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Aether: \(message)"])
  }

  /// iOS already shows the system VPN pill on connect, so the only notification
  /// worth posting is an unexpected drop: the moment traffic stops being
  /// protected without the user asking for it. A user-initiated stop (they hit
  /// Disconnect, switched servers, signed out, or the config was replaced) stays
  /// silent. Delivered with provisional authorization so it lands quietly in
  /// Notification Center with no permission prompt.
  private func notifyIfUnexpected(_ reason: NEProviderStopReason) {
    switch reason {
    case .userInitiated,        // they tapped Disconnect
         .superceded,           // replaced by a newer connection
         .userLogout,
         .userSwitch,
         .configurationDisabled,
         .configurationRemoved,
         .noNetworkAvailable,   // transient; iOS brings it back
         .sleep,                // device slept
         .appUpdate,            // the app is being updated
         .idleTimeout:          // on-demand let an idle tunnel go
      // Expected, or user-driven. Saying "you are unprotected" here would be
      // both wrong and constant.
      return
    default:
      // providerFailed, connectionFailed, unrecoverableNetworkChange,
      // configurationFailed, internalError and friends: the tunnel went down
      // and the user did not ask for it, which is the case worth telling them
      // about.
      break
    }
    let content = UNMutableNotificationContent()
    content.title = "Nova disconnected"
    content.body = "Your traffic is no longer protected. Open Nova to reconnect."
    content.sound = nil
    let request = UNNotificationRequest(
      identifier: "nova.vpn.dropped",
      content: content,
      trigger: nil,
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  private lazy var commandServerHandler = CommandServerHandler(provider: self)
}

/// Sinks Xray's log records to a shared App Group file the app tails. The NE is a
/// separate process from the app, so — unlike Android's in-process VpnService,
/// which pushes straight to the Flutter engine — Xray's lines have to cross to the
/// app through shared storage. Keeps a bounded in-memory ring and rewrites the
/// whole file atomically per line (Xray runs at warning level, so the volume is
/// low); rewriting the whole ring means the app never has to track a byte offset
/// across truncation.
final class XrayLogSink: NSObject, NovaxrayLoggerProtocol {
  private let url: URL
  private let queue = DispatchQueue(label: "online.novaproxy.xraylog")
  private var ring: [String] = []
  private static let maxLines = 500

  init(url: URL) { self.url = url }

  func log(_ line: String?) {
    guard let line = line, !line.isEmpty else { return }
    queue.async {
      self.ring.append(line)
      if self.ring.count > Self.maxLines {
        self.ring.removeFirst(self.ring.count - Self.maxLines)
      }
      let body = self.ring.joined(separator: "\n") + "\n"
      try? body.data(using: .utf8)?.write(to: self.url, options: .atomic)
    }
  }
}

/// Minimal command-server handler. The traffic/status stream the app consumes
/// needs a running server; the system-proxy and reload hooks are not used on
/// the iOS packet-tunnel path, so they answer with safe defaults.
private final class CommandServerHandler: NSObject, NovacoreCommandServerHandlerProtocol {
  private weak var provider: PacketTunnelProvider?
  init(provider: PacketTunnelProvider) { self.provider = provider }

  func getSystemProxyStatus() throws -> NovacoreSystemProxyStatus {
    let status = NovacoreSystemProxyStatus()
    status.available = false
    status.enabled = false
    return status
  }

  // 1.13 replaced postServiceClose with serviceStop; both are unused on the
  // packet-tunnel path (the extension owns its own lifecycle).
  func serviceStop() throws {}

  func serviceReload() throws {}
  func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
    throw NSError(domain: "Nova", code: 6, userInfo: [NSLocalizedDescriptionKey: "SSH agent is not supported"])
  }
  func triggerNativeCrash() throws {
    throw NSError(domain: "Nova", code: 6, userInfo: [NSLocalizedDescriptionKey: "Crash requests are disabled"])
  }


  func setSystemProxyEnabled(_ enabled: Bool) throws {}

  // Added in sing-box 1.13's command-server handler.
  func writeDebugMessage(_ message: String?) {}
}

// MARK: - NovacorePlatformInterface

extension PacketTunnelProvider: NovacorePlatformInterfaceProtocol {
  func openTun(_ options: NovacoreTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    guard let options, let ret0_ else {
      throw NSError(domain: "Nova", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nil tun options"])
    }
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = NSNumber(value: options.getMTU())

    // DNS (a single boxed server address)
    if let iterator = try? options.getDNSServerAddress() {
      var servers: [String] = []
      while iterator.hasNext() { servers.append(iterator.next()) }
      if !servers.isEmpty { settings.dnsSettings = NEDNSSettings(servers: servers) }
    }

    // IPv4 addresses + default route.
    var v4addr: [String] = [], v4mask: [String] = []
    if let it = options.getInet4Address() {
      while it.hasNext() { let p = it.next()!; v4addr.append(p.address()); v4mask.append(p.mask()) }
    }
    if !v4addr.isEmpty {
      let v4 = NEIPv4Settings(addresses: v4addr, subnetMasks: v4mask)
      // Included routes: what sing-box wants tunneled (default route if none).
      var inc: [NEIPv4Route] = []
      if let it = options.getInet4RouteAddress() {
        while it.hasNext() { let p = it.next()!; inc.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask())) }
      }
      v4.includedRoutes = inc.isEmpty ? [NEIPv4Route.default()] : inc
      // Excluded routes: sing-box lists the proxy server IPs (and LAN) here so
      // the core's own outbound connection to them goes out the real interface
      // instead of looping back through the tunnel. Without this the upload
      // SYN escapes but the return path loops — connected, upload, zero download.
      var exc: [NEIPv4Route] = []
      if let it = options.getInet4RouteExcludeAddress() {
        while it.hasNext() { let p = it.next()!; exc.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask())) }
      }
      if !exc.isEmpty { v4.excludedRoutes = exc }
      settings.ipv4Settings = v4
    }

    // IPv6 addresses + routes.
    var v6addr: [String] = []; var v6prefix: [NSNumber] = []
    if let it = options.getInet6Address() {
      while it.hasNext() { let p = it.next()!; v6addr.append(p.address()); v6prefix.append(NSNumber(value: p.prefix())) }
    }
    if !v6addr.isEmpty {
      let v6 = NEIPv6Settings(addresses: v6addr, networkPrefixLengths: v6prefix)
      var inc6: [NEIPv6Route] = []
      if let it = options.getInet6RouteAddress() {
        while it.hasNext() { let p = it.next()!; inc6.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix()))) }
      }
      v6.includedRoutes = inc6.isEmpty ? [NEIPv6Route.default()] : inc6
      var exc6: [NEIPv6Route] = []
      if let it = options.getInet6RouteExcludeAddress() {
        while it.hasNext() { let p = it.next()!; exc6.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix()))) }
      }
      if !exc6.isEmpty { v6.excludedRoutes = exc6 }
      settings.ipv6Settings = v6
    }

    // System HTTP/HTTPS proxy. When the config's tun `platform.http_proxy` is
    // enabled, sing-box runs the proxy listener and hands us its address here;
    // we register it via NEProxySettings so apps that honour the system proxy
    // (and skip the packet route) still get tunneled. Without this some apps get
    // no proxy at all.
    if options.isHTTPProxyEnabled() {
      let proxySettings = NEProxySettings()
      let server = NEProxyServer(
        address: options.getHTTPProxyServer(),
        port: Int(options.getHTTPProxyServerPort()))
      proxySettings.httpServer = server
      proxySettings.httpsServer = server
      proxySettings.httpEnabled = true
      proxySettings.httpsEnabled = true
      // Only constrain the match list if sing-box actually names domains;
      // leaving it nil (the default) makes the proxy apply to ALL connections,
      // which is what we want to catch route-skipping apps.
      var matchDomains: [String] = []
      if let it = options.getHTTPProxyMatchDomain() {
        while it.hasNext() { matchDomains.append(it.next()) }
      }
      if !matchDomains.isEmpty { proxySettings.matchDomains = matchDomains }
      var bypassDomains: [String] = []
      if let it = options.getHTTPProxyBypassDomain() {
        while it.hasNext() { bypassDomains.append(it.next()) }
      }
      if !bypassDomains.isEmpty { proxySettings.exceptionList = bypassDomains }
      settings.proxySettings = proxySettings
    }

    // setTunnelNetworkSettings is async; bridge to sync for libbox.
    let sem = DispatchSemaphore(value: 0)
    var applyError: Error?
    setTunnelNetworkSettings(settings) { error in applyError = error; sem.signal() }
    sem.wait()
    if let applyError { throw applyError }

    // The TUN file descriptor for libbox. The private `socket.fileDescriptor`
    // KVC path works on older iOS but returns nil on newer releases (e.g.
    // iOS 18+/26), so fall back to libbox's own tunnel-fd lookup — without this
    // the tunnel fails to come up a few seconds in ("No tun fd").
    if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd != -1 {
      ret0_.pointee = fd
      return
    }
    let loopFd = NovacoreGetTunnelFileDescriptor()
    if loopFd != -1 {
      ret0_.pointee = loopFd
    } else {
      throw NSError(domain: "Nova", code: 4, userInfo: [NSLocalizedDescriptionKey: "No tun fd"])
    }
  }

  // Added in sing-box 1.12's NovacorePlatformInterface. We provide neither a
  // custom local DNS transport nor a platform certificate list, so sing-box uses
  // its own DNS handling (our config's remote/local servers) and the bundled
  // system trust store. Returning nil is the "use defaults" contract.
  func localDNSTransport() -> NovacoreLocalDNSTransportProtocol? { nil }
  func systemCertificates() -> NovacoreStringIteratorProtocol? { nil }
  func useProcFS() -> Bool { false }
  func underNetworkExtension() -> Bool { true }
  func includeAllNetworks() -> Bool { false }
  // Let sing-box bind outbound sockets to the real default interface itself
  // (via startDefaultInterfaceMonitor below). Returning true here with an empty
  // autoDetectControl left the proxy's sockets unbound, so requests went out
  // but nothing came back ("connected, upload only, no download").
  func usePlatformAutoDetectControl() -> Bool { false }
  func autoDetectControl(_: Int32) throws {}
  func clearDNSCache() {}

  // Optional 1.14 platform services are not exposed by Nova's tunnel.
  func cancelNotification(_: String?, typeID _: Int32) throws {}
  func registerMyInterface(_: String?) {}
  func tailscaleHostname() -> String { "Nova" }
  func usePlatformBridge() -> Bool { false }
  func usePlatformShell() -> Bool { false }
  private func unsupportedPlatformService() -> NSError {
    NSError(domain: "Nova", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Platform service is not supported"])
  }
  func checkPlatformShell() throws { throw unsupportedPlatformService() }
  func createBridge(_: NovacoreBridgeOptions?) throws -> NovacoreBridgeSessionProtocol {
    throw unsupportedPlatformService()
  }
  func lookupSFTPServer(_ error: NSErrorPointer) -> String {
    error?.pointee = unsupportedPlatformService()
    return ""
  }
  func lookupUser(_: String?) throws -> NovacorePlatformUser { throw unsupportedPlatformService() }
  func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
    error?.pointee = unsupportedPlatformService()
    return ""
  }
  func openShellSession(_: NovacorePlatformUser?, command _: String?,
                        environ _: NovacoreStringIteratorProtocol?, term _: String?,
                        rows _: Int32, cols _: Int32) throws -> NovacoreShellSessionProtocol {
    throw unsupportedPlatformService()
  }
  func startNeighborMonitor(_: NovacoreNeighborUpdateListenerProtocol?) throws {}
  func closeNeighborMonitor(_: NovacoreNeighborUpdateListenerProtocol?) throws {}


  func startDefaultInterfaceMonitor(_ listener: NovacoreInterfaceUpdateListenerProtocol?) throws {
    guard let listener else { return }
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    // Block until the first path update is delivered, so sing-box knows the real
    // default interface BEFORE it dials any outbound. Returning early let it bind
    // outbounds to the tunnel itself -> loop -> connected but zero download.
    let semaphore = DispatchSemaphore(value: 0)
    monitor.pathUpdateHandler = { path in
      self.report(listener, path)
      semaphore.signal()
      monitor.pathUpdateHandler = { path in self.report(listener, path) }
    }
    monitor.start(queue: DispatchQueue.global())
    semaphore.wait()
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

  // sing-box enumerates interfaces here to bind outbound sockets to the physical
  // one. Throwing (as before) left it unable to bind -> traffic looped -> zero
  // download. Return the live interfaces from the path monitor.
  func getInterfaces() throws -> NovacoreNetworkInterfaceIteratorProtocol {
    guard let path = pathMonitor?.currentPath, path.status != .unsatisfied else {
      return InterfaceArray([])
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
    return InterfaceArray(out)
  }

  // 1.13 changed this to return a NovacoreConnectionOwner instead of an out-param;
  // process/owner lookup is unsupported in the iOS extension, so return nil.
  func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                           destinationAddress _: String?, destinationPort _: Int32) throws -> NovacoreConnectionOwner {
    throw NSError(domain: "Nova", code: 6, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
  }

  func readWIFIState() -> NovacoreWIFIState? { nil }
  func send(_: NovacoreNotification?) throws {}
}

/// Bridges a Swift array of interfaces to libbox's iterator protocol so the core
/// can enumerate the device's network interfaces.
private final class InterfaceArray: NSObject, NovacoreNetworkInterfaceIteratorProtocol {
  private var iterator: IndexingIterator<[NovacoreNetworkInterface]>
  private var current: NovacoreNetworkInterface?
  init(_ array: [NovacoreNetworkInterface]) { iterator = array.makeIterator() }
  func hasNext() -> Bool {
    current = iterator.next()
    return current != nil
  }
  func next() -> NovacoreNetworkInterface? { current }
}
