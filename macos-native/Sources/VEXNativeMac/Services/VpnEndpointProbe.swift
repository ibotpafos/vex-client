import Foundation

/// A network probe must stop when its deadline or caller wins, even when the
/// underlying connection stays in a waiting state and never calls back.
enum VpnEndpointProbe {
    typealias Finish = @Sendable (VpnAutopilotProbeResult) -> Void
    typealias Cancel = @Sendable () -> Void

    static func run(
        timeout: Duration = .seconds(3),
        start: @escaping @Sendable (@escaping Finish) -> Cancel
    ) async -> VpnAutopilotProbeResult {
        guard !Task.isCancelled else { return .empty }
        return await withTaskGroup(of: VpnAutopilotProbeResult.self) { group in
            group.addTask {
                await connection(start: start)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return .empty
                }
                guard !Task.isCancelled else { return .empty }
                return VpnAutopilotProbeResult(dnsOk: true, endpointProbeError: "endpoint probe timed out")
            }
            let result = await group.next() ?? .empty
            group.cancelAll()
            return result
        }
    }

    private static func connection(
        start: @escaping @Sendable (@escaping Finish) -> Cancel
    ) async -> VpnAutopilotProbeResult {
        let completion = EndpointProbeCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else { return }
                let cancel = start { result in completion.finish(result) }
                completion.installCancellation(cancel)
            }
        } onCancel: {
            completion.finish(.empty)
        }
    }
}

private final class EndpointProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: VpnAutopilotProbeResult?
    private var continuation: CheckedContinuation<VpnAutopilotProbeResult, Never>?
    private var cancellation: VpnEndpointProbe.Cancel?

    func install(_ continuation: CheckedContinuation<VpnAutopilotProbeResult, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installCancellation(_ cancellation: @escaping VpnEndpointProbe.Cancel) {
        lock.lock()
        let finished = result != nil
        if !finished { self.cancellation = cancellation }
        lock.unlock()
        if finished { cancellation() }
    }

    func finish(_ result: VpnAutopilotProbeResult) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let cancellation = self.cancellation
        self.continuation = nil
        self.cancellation = nil
        lock.unlock()
        cancellation?()
        continuation?.resume(returning: result)
    }
}

struct VpnAutopilotProbeResult: Equatable, Sendable {
    var dnsOk: Bool?
    var endpointLatencyMs: Double?
    var endpointProbeError: String?
    var httpsOk: Bool?
    var httpsProbeError: String?

    static let empty = VpnAutopilotProbeResult()

    func merged(with other: VpnAutopilotProbeResult) -> VpnAutopilotProbeResult {
        VpnAutopilotProbeResult(
            dnsOk: other.dnsOk ?? dnsOk,
            endpointLatencyMs: other.endpointLatencyMs ?? endpointLatencyMs,
            endpointProbeError: other.endpointProbeError ?? endpointProbeError,
            httpsOk: other.httpsOk ?? httpsOk,
            httpsProbeError: other.httpsProbeError ?? httpsProbeError
        )
    }
}
