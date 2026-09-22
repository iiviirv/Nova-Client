"""Run the actual Swift manager-selection method against a fake preferences API."""
from pathlib import Path
import subprocess
import tempfile

source = Path('macos/Runner/NovaTunnelHost.swift').read_text()
start = source.index('  private func loadManager(')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
harness = '''import Foundation
class NETunnelProviderProtocol {
  var providerBundleIdentifier: String
  init(_ id: String) { providerBundleIdentifier = id }
}
class NETunnelProviderManager {
  var protocolConfiguration: Any?
  init(_ id: String) { protocolConfiguration = NETunnelProviderProtocol(id) }
  static var items: [NETunnelProviderManager] = []
  static var failure: Error?
  static func loadAllFromPreferences(_ done: ([NETunnelProviderManager]?, Error?) -> Void) {
    done(items, failure)
  }
}
class Host {
  static let extensionBundleId = "nova"
  private var manager: NETunnelProviderManager?
  METHOD
  func run(_ done: @escaping (NETunnelProviderManager?, Error?) -> Void) { loadManager(done) }
}
let host = Host()
let foreign = NETunnelProviderManager("other-vpn")
let nova = NETunnelProviderManager("nova")
NETunnelProviderManager.items = [foreign, nova]
host.run { found, error in precondition(found === nova && error == nil) }
NETunnelProviderManager.items = [foreign]
host.run { found, error in precondition(found == nil && error == nil) }
NETunnelProviderManager.items = [nova]
NETunnelProviderManager.failure = NSError(domain: "test", code: 1)
host.run { found, error in precondition(found == nil && error != nil) }
print("3 macOS manager selection checks passed")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='nova-manager-test-') as tmp:
    path = Path(tmp)
    (path / 'main.swift').write_text(harness)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
