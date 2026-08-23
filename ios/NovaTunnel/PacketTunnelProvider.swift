import Foundation
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
    if xrayStarted {
      xrayStarted = false
      NovaxraySetLogger(nil)
      _ = NovaxrayStop()
    }
    xrayLogSink = nil
    notifyIfUnexpected(reason)
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
    if let dnsBox = try? options.getDNSServerAddress(), !dnsBox.value.isEmpty {
      settings.dnsSettings = NEDNSSettings(servers: [dnsBox.value])
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
