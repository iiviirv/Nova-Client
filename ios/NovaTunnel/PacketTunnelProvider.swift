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
    try service.start()
  }

  override func stopTunnel(with _: NEProviderStopReason) async {
    pathMonitor?.cancel()
    pathMonitor = nil
    try? boxService?.close()
    boxService = nil
  }
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
      v4.includedRoutes = [NEIPv4Route.default()]
      settings.ipv4Settings = v4
    }

    // IPv6 addresses + default route.
    var v6addr: [String] = []; var v6prefix: [NSNumber] = []
    if let it = options.getInet6Address() {
      while it.hasNext() { let p = it.next()!; v6addr.append(p.address()); v6prefix.append(NSNumber(value: p.prefix())) }
    }
    if !v6addr.isEmpty {
      let v6 = NEIPv6Settings(addresses: v6addr, networkPrefixLengths: v6prefix)
      v6.includedRoutes = [NEIPv6Route.default()]
      settings.ipv6Settings = v6
    }

    // setTunnelNetworkSettings is async; bridge to sync for libbox.
    let sem = DispatchSemaphore(value: 0)
    var applyError: Error?
    setTunnelNetworkSettings(settings) { error in applyError = error; sem.signal() }
    sem.wait()
    if let applyError { throw applyError }

    // The TUN file descriptor for libbox is the packet flow's underlying socket.
    if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
      ret0_.pointee = fd
    } else {
      throw NSError(domain: "Nova", code: 4, userInfo: [NSLocalizedDescriptionKey: "No tun fd"])
    }
  }

  func writeLog(_ message: String?) { if let message { NSLog("[sing-box] %@", message) } }
  func useProcFS() -> Bool { false }
  func underNetworkExtension() -> Bool { true }
  func includeAllNetworks() -> Bool { false }
  func usePlatformAutoDetectControl() -> Bool { true }
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
