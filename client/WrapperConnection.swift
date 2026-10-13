import Combine
import Foundation

/// Where the user's own wrapper-v2 instance listens. Helix ships no
/// Apple code and no wrapper; the user runs wrapper-v2 themselves (Docker on
/// this Mac or on a machine in the local network) and enters its address here.
struct WrapperEndpoint: Equatable, Sendable {
    static let hostKey = "wrapperHost", httpPortKey = "wrapperHTTPPort", decryptPortKey = "wrapperDecryptPort"
    /// wrapper-v2's Compose defaults.
    static let defaultHost = "127.0.0.1", defaultHTTPPort = 80, defaultDecryptPort = 10020

    var host: String
    var httpPort: Int
    var decryptPort: Int

    static var saved: WrapperEndpoint {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: hostKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let http = defaults.integer(forKey: httpPortKey), decrypt = defaults.integer(forKey: decryptPortKey)
        return WrapperEndpoint(host: host.isEmpty ? defaultHost : host,
                               httpPort: (1...65535).contains(http) ? http : defaultHTTPPort,
                               decryptPort: (1...65535).contains(decrypt) ? decrypt : defaultDecryptPort)
    }
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Self.hostKey); defaults.set(httpPort, forKey: Self.httpPortKey); defaults.set(decryptPort, forKey: Self.decryptPortKey)
    }
    var httpBase: URL? {
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = httpPort
        return components.url
    }
    var label: String { "\(host):\(httpPort)" }
}

/// Connection state of the user's wrapper. Replaces the old embedded runtime:
/// nothing is started or stopped here, the app only checks reachability.
@MainActor
final class WrapperConnection: ObservableObject {
    @Published private(set) var endpoint = WrapperEndpoint.saved
    @Published private(set) var ready = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Checking the wrapper connection …"
    @Published private(set) var failure: String?

    var service: WrapperService { WrapperService(endpoint: endpoint) }

    func connect() async {
        guard !connecting else { return }
        connecting = true; failure = nil; ready = false
        status = "Checking \(endpoint.label) …"
        defer { connecting = false }
        do {
            guard endpoint.httpBase != nil else { throw ClientError.message("The wrapper address is invalid.") }
            let account = try await service.account()
            guard account.ready else {
                throw ClientError.message("The wrapper at \(endpoint.label) is running but not ready for playback yet. Check its log and try again.")
            }
            ready = true; status = "Connected to \(endpoint.label)"
        } catch let error as ClientError {
            failure = error.errorDescription; status = "Not connected"
        } catch {
            failure = "No wrapper-v2 answers at \(endpoint.label). Check the address and ports and whether the wrapper is running."
            status = "Not connected"
        }
    }
    /// Stores a new address; `AppModel.connectWrapper()` then connects to it.
    func update(_ endpoint: WrapperEndpoint) async {
        endpoint.save(); self.endpoint = endpoint
        await DecryptChannel.shared.reset()
    }
}
