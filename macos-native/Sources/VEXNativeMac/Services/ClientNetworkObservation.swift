import Foundation
import Network

struct ClientNetworkSnapshot: Equatable {
    var networkClass: String
    var generation: String
}

// Read-only path observations never retain or send addresses, SSIDs or router
// identities. Every path change invalidates correlation conservatively, even
// when it is caused by a tunnel change rather than a physical network change.
final class ClientNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var state = ClientNetworkSnapshot(networkClass: "unknown", generation: "")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind = path.status != .satisfied ? "unknown" : path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "unknown"
            self.lock.lock()
            self.state = ClientNetworkSnapshot(networkClass: kind, generation: UUID().uuidString)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "app.vexguard.client-network-diagnostics"))
    }

    deinit { monitor.cancel() }

    func snapshot() -> ClientNetworkSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

struct CapturedClientNetwork {
    var snapshot: ClientNetworkSnapshot
    var id: String
    var deviceId: String
    var accessToken: String
    var capturedAt: Date

    func matches(_ current: ClientNetworkSnapshot, device: String?, token: String, now: Date) -> Bool {
        !current.generation.isEmpty && current == snapshot && device == deviceId && token == accessToken &&
        now >= capturedAt && now.timeIntervalSince(capturedAt) <= 6 * 60 * 60
    }
}
