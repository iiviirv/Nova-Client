import Foundation
import Network
import NetworkExtension
import Novacore

/// The sing-box Network Extension for macOS.
///
/// This is why the Mac stops asking for a password. Running a tunnel means
/// creating a utun device, which needs root, and until now Nova got there by
/// asking for administrator rights on every single connect. A system extension
/// is approved once, by the user, in System Settings, and after that macOS
/// starts it with the privileges it needs. It is also what puts "Nova" in the
/// Network pane next to Wi-Fi, the way every other VPN appears there.
///
/// It is a near-copy of the iOS provider (ios/NovaTunnel/PacketTunnelProvider),
/// which is the point: the same core, the same libbox platform interface, the
/// same behaviour on both. Differences are marked where they exist, and there
/// are only three: no UIKit link, no dropped-tunnel notification (the Mac app is
/// right there), and the app group is team-prefixed, which macOS requires.
class PacketTunnelProvider: NEPacketTunnelProvider {
  /// macOS requires the team identifier prefix on an app group used by an
  /// app that is not sandboxed, which Nova is not.
  static let appGroup = "A53J987N2C.group.online.novaproxy.novaClient"

  private var commandServer: NovacoreCommandServer?
  private var xrayStarted = false
  private var xrayLogSink: XrayLogSink?
  private var pathMonitor: NWPathMonitor?

  /// Written into the shared container as the tunnel starts, and appended to on
  /// the way through. A packet tunnel that fails inside a system extension logs
  /// nowhere the app can see, so this is the difference between a diagnosis and
  /// a guess.
  private func trace(_ line: String) {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
    let url = container.appendingPathComponent("tunnel.log")
    let stamped = "\(Date()) \(line)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(stamped.utf8))
      try? handle.close()
    } else {
      try? Data(stamped.utf8).write(to: url)
    }
  }

  override func startTunnel(options _: [String: NSObject]?) async throws {
    trace("startTunnel")
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      throw NSError(domain: "Nova", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "App Group missing"])
    }
    let base = container.path
    let setup = NovacoreSetupOptions()
    setup.basePath = base
    setup.workingPath = container.appendingPathComponent("work").path
    setup.tempPath = container.appendingPathComponent("tmp").path
    try? FileManager.default.createDirectory(atPath: setup.workingPath,
                                             withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: setup.tempPath,
                                             withIntermediateDirectories: true)
    var setupErr: NSError?
    NovacoreSetup(setup, &setupErr)
    trace("setup done err=\(setupErr?.localizedDescription ?? "none")")

    let config = try String(contentsOf: container.appendingPathComponent("config.json"),
                            encoding: .utf8)

    // xhttp node: Xray runs first so its local SOCKS inbound is up before
    // sing-box bridges the tunnel to it. Same two-core arrangement as iPhone.
    let xrayURL = container.appendingPathComponent("xray.json")
    if let xrayCfg = try? String(contentsOf: xrayURL, encoding: .utf8), !xrayCfg.isEmpty {
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

    var err: NSError?
    guard let server = NovacoreNewCommandServer(commandServerHandler, self, &err), err == nil else {
      throw err ?? NSError(domain: "Nova", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "Failed to create command server"])
    }
    trace("command server created")
    try server.start()
    // A real (empty) options object, never nil: libbox 1.13 dereferences it.
    do {
      try server.startOrReloadService(config, options: NovacoreOverrideOptions())
    } catch {
      trace("startOrReloadService failed: \(error.localizedDescription)")
      throw error
    }
    trace("service started")
    commandServer = server
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    trace("stopTunnel reason=\(reason.rawValue)")
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
  }

  private lazy var commandServerHandler = CommandServerHandler(provider: self)
}

/// Sinks Xray's log records to a shared file the app tails, because the
/// extension is a separate process and cannot hand lines to Flutter directly.
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

/// Minimal command-server handler: the traffic and status stream needs a running
/// server, and the system-proxy hooks are not used on this path.
private final class CommandServerHandler: NSObject, NovacoreCommandServerHandlerProtocol {
  private weak var provider: PacketTunnelProvider?
  init(provider: PacketTunnelProvider) { self.provider = provider }

  func getSystemProxyStatus() throws -> NovacoreSystemProxyStatus {
    let status = NovacoreSystemProxyStatus()
    status.available = false
    status.enabled = false
    return status
  }

  func serviceStop() throws {}
  func serviceReload() throws {}
  func setSystemProxyEnabled(_: Bool) throws {}
  func writeDebugMessage(_: String?) {}
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

  // Per-process attribution is not something this tunnel is asked for, so it
  // answers the same way the iPhone extension does.
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
