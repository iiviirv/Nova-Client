import Foundation
import Libbox
import Network
import NetworkExtension

/// The sing-box Network Extension for iOS. Reads the config the app wrote to the
/// shared App Group, sets up the TUN from sing-box's requested options, and runs
/// the core. The provider is the libbox PlatformInterface (TUN + interface
/// monitor), mirroring the Android VpnService host.
///
/// openTun and the interface monitor are adapted from sing-box-for-apple's
/// ExtensionPlatformInterface; if you hit routing edge cases, cross-check against
/// that reference (it is built against this same Libbox.xcframework).
class PacketTunnelProvider: NEPacketTunnelProvider {
  static let appGroup = "group.online.novaproxy.novaClient"

  private var boxService: LibboxBoxService?
  private var commandServer: LibboxCommandServer?
  private var pathMonitor: NWPathMonitor?

  override func startTunnel(options _: [String: NSObject]?) async throws {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
      throw NSError(domain: "Nova", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group missing"])
    }
    let base = container.path
    let setup = LibboxSetupOptions()
    setup.basePath = base
    setup.workingPath = container.appendingPathComponent("work").path
    setup.tempPath = container.appendingPathComponent("tmp").path
    try? FileManager.default.createDirectory(atPath: setup.workingPath, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: setup.tempPath, withIntermediateDirectories: true)
    var setupErr: NSError?
    LibboxSetup(setup, &setupErr)

    let config = try String(contentsOf: container.appendingPathComponent("config.json"), encoding: .utf8)

    var err: NSError?
    guard let service = LibboxNewService(config, self, &err), err == nil else {
      throw err ?? NSError(domain: "Nova", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create service"])
    }
    boxService = service

    // Stand up the libbox command server on the shared App Group socket so the
    // main app can attach a status client and read live traffic stats. Failure
    // here must not block the tunnel itself, so it is best-effort.
    let server = LibboxNewCommandServer(commandServerHandler, 100)
    if let server {
      try? server.start()
      server.setService(service)
      commandServer = server
    }

    try service.start()
  }

  override func stopTunnel(with _: NEProviderStopReason) async {
    pathMonitor?.cancel()
    pathMonitor = nil
    try? boxService?.close()
    boxService = nil
    try? commandServer?.close()
    commandServer = nil
  }

  private lazy var commandServerHandler = CommandServerHandler(provider: self)
}

/// Minimal command-server handler. The traffic/status stream the app consumes
/// needs a running server; the system-proxy and reload hooks are not used on
/// the iOS packet-tunnel path, so they answer with safe defaults.
private final class CommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {
  private weak var provider: PacketTunnelProvider?
  init(provider: PacketTunnelProvider) { self.provider = provider }

  func getSystemProxyStatus() -> LibboxSystemProxyStatus? {
    let status = LibboxSystemProxyStatus()
    status.available = false
    status.enabled = false
    return status
  }

  func postServiceClose() {}

  func serviceReload() throws {}

  func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
}

// MARK: - LibboxPlatformInterface

extension PacketTunnelProvider: LibboxPlatformInterfaceProtocol {
  func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
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
    let loopFd = LibboxGetTunnelFileDescriptor()
    if loopFd != -1 {
      ret0_.pointee = loopFd
    } else {
      throw NSError(domain: "Nova", code: 4, userInfo: [NSLocalizedDescriptionKey: "No tun fd"])
    }
  }

  func writeLog(_ message: String?) { if let message { NSLog("[sing-box] %@", message) } }
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

  func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { path in
      let iface = path.availableInterfaces.first
      let name = iface?.name ?? ""
      let index = Int32(iface?.index ?? 0)
      listener?.updateDefaultInterface(name, interfaceIndex: index,
                                       isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
    monitor.start(queue: DispatchQueue(label: "nova.path"))
  }

  func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  // Not applicable on iOS NE; the interface monitor above provides routing.
  func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
    throw NSError(domain: "Nova", code: 5, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
  }

  func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                           destinationAddress _: String?, destinationPort _: Int32,
                           ret0_: UnsafeMutablePointer<Int32>?) throws {
    throw NSError(domain: "Nova", code: 6, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
  }

  func packageName(byUid _: Int32, error _: NSErrorPointer) -> String { "" }
  func uid(byPackageName _: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    throw NSError(domain: "Nova", code: 7, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
  }

  func readWIFIState() -> LibboxWIFIState? { nil }
  func send(_: LibboxNotification?) throws {}
}
