import Foundation
import Network

struct VpnAutopilotService {
    private let api: VEXAPIClient
    private let endpointFallbackPorts: [UInt16] = [443, 51820]
    private let staleHandshakeSeconds: TimeInterval = 180

    init(api: VEXAPIClient = VEXAPIClient()) {
        self.api = api
    }

    func probe(endpoint: String?) async -> VpnAutopilotProbeResult {
        async let endpointProbe = probeEndpoint(endpoint)
        async let httpsProbe = probeHTTPS()
        return await endpointProbe.merged(with: httpsProbe)
    }

    func assess(error: Error? = nil, healthReasons: [NativeTunnelHealthReason] = [], status: VpnStatus? = nil, probe: VpnAutopilotProbeResult = .empty) -> VpnAutopilotAssessment {
        let messages = [
            error?.localizedDescription.lowercased(),
            probe.endpointProbeError?.lowercased(),
            probe.httpsProbeError?.lowercased(),
        ].compactMap { $0 }.joined(separator: " ")

        let cause: VpnAutopilotCause
        if matches(messages, ["подписка", "subscription", "entitlement", "payment required", "access inactive"]) {
            cause = .subscription
        } else if matches(messages, ["разрешение", "permission", "not authorized", "unauthorized"]) {
            cause = .permission
        } else if matches(messages, ["revoked", "profile", "config", "public key", "private key", "wireguard key", "rotation"]) {
            cause = .keyOrProfile
        } else if probe.dnsOk == false || matches(messages, ["dns", "resolve", "lookup", "name resolution", "nodename nor servname"]) {
            cause = .dns
        } else if probe.httpsOk == false || matches(messages, ["offline", "no internet", "timed out", "timeout", "network connection was lost", "cancelled", "canceled"]) {
            cause = .network
        } else if healthReasons.contains(where: { [.deviceUsageDegraded, .staleLocalHandshake, .localStatusError].contains($0) })
                    || matches(messages, ["handshake", "endpoint", "peer", "stale", "no_handshake", "missing_peer"])
                    || (probe.endpointLatencyMs ?? 0) > 900 {
            cause = .server
        } else if healthReasons.contains(.leakBlocking) || healthReasons.contains(.localStatusDisconnected) {
            cause = .network
        } else {
            cause = .unknown
        }

        return VpnAutopilotAssessment(
            cause: cause,
            canFailover: cause == .server || cause == .dns,
            diagnosticStatus: cause.rawValue,
            userMessage: userMessage(for: cause),
            samples: [
                "autopilot_cause": cause.rawValue,
                "autopilot_can_failover": cause == .server || cause == .dns ? "true" : "false",
                "dns_ok": probe.dnsOk.map(String.init) ?? "",
                "https_ok": probe.httpsOk.map(String.init) ?? "",
                "endpoint_latency_ms": probe.endpointLatencyMs.map { String(Int($0)) } ?? "",
                "endpoint_probe_error": probe.endpointProbeError ?? "",
                "https_probe_error": probe.httpsProbeError ?? "",
                "health_reasons": healthReasons.map(\.rawValue).joined(separator: ","),
                "local_status_state": status?.state.rawValue ?? "",
            ].filter { !$0.value.isEmpty }
        )
    }

    func healthReasons(status: VpnStatus, usage: VpnDeviceUsage?, now: Date = Date()) -> [NativeTunnelHealthReason] {
        var reasons: [NativeTunnelHealthReason] = []
        if let usage, deviceUsageNeedsReconnect(usage) {
            reasons.append(.deviceUsageDegraded)
        }
        if status.leakProtection == "blocking" {
            reasons.append(.leakBlocking)
        }
        switch status.state {
        case .disconnected:
            reasons.append(.localStatusDisconnected)
        case .connected, .connecting, .disconnecting:
            break
        }
        if let latestHandshake = status.latestHandshake {
            let age = now.timeIntervalSince1970 - TimeInterval(latestHandshake)
            if age > staleHandshakeSeconds {
                reasons.append(.staleLocalHandshake)
            }
        }
        return reasons
    }

    func usage(accessToken: String, deviceId: String?) async -> VpnDeviceUsage? {
        guard let deviceId, !deviceId.isEmpty else { return nil }
        return try? await api.vpnDeviceUsage(accessToken: accessToken).first { $0.deviceId == deviceId }
    }

    func fallbackTunnels(for tunnel: PreparedTunnel) -> [PreparedTunnel] {
        var attempts: [PreparedTunnel] = []
        if let lastSuccessfulEndpoint = tunnel.lastSuccessfulEndpoint,
           let candidate = tunnel.withEndpoint(lastSuccessfulEndpoint) {
            attempts.append(candidate)
        }
        attempts.append(tunnel)
        for port in endpointFallbackPorts {
            if let candidate = tunnel.withEndpointPort(port) {
                attempts.append(candidate)
            }
        }
        var seen = Set<String>()
        return attempts.filter { attempt in
            let endpoint = attempt.endpoint ?? attempt.configEndpoint ?? attempt.config
            return seen.insert(endpoint).inserted
        }
    }

    private func probeHTTPS() async -> VpnAutopilotProbeResult {
        var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/app/remote-config"
        components?.query = nil
        guard let url = components?.url else { return .empty }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return VpnAutopilotProbeResult(httpsOk: status > 0 && status < 500)
        } catch {
            return VpnAutopilotProbeResult(httpsOk: false, httpsProbeError: error.localizedDescription)
        }
    }

    private func probeEndpoint(_ endpoint: String?) async -> VpnAutopilotProbeResult {
        guard let parsed = ParsedEndpoint(endpoint) else { return .empty }
        let started = Date()
        return await withTaskGroup(of: VpnAutopilotProbeResult.self) { group in
            group.addTask {
                await connectProbe(host: parsed.host, port: parsed.port, started: started)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return VpnAutopilotProbeResult(dnsOk: true, endpointLatencyMs: nil, endpointProbeError: "endpoint probe timed out")
            }
            let result = await group.next() ?? .empty
            group.cancelAll()
            return result
        }
    }

    private func deviceUsageNeedsReconnect(_ usage: VpnDeviceUsage) -> Bool {
        if let seconds = usage.secondsSinceHandshake, seconds > Int(staleHandshakeSeconds) {
            return true
        }
        if usage.connected == true {
            return false
        }
        return ["stale", "no_handshake", "missing_peer", "never_connected"].contains(usage.connectionStatus ?? "")
    }

    private func matches(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private func userMessage(for cause: VpnAutopilotCause) -> String {
        switch cause {
        case .dns:
            return "Проблема с туннелем: DNS недоступен."
        case .keyOrProfile:
            return "Проблема с туннелем: обновляем ключ VPN."
        case .network:
            return "Проблема с туннелем: сеть нестабильна."
        case .permission:
            return "Проблема с туннелем: нужно разрешение VPN."
        case .server:
            return "Проблема с туннелем: сервер нестабилен."
        case .subscription:
            return "Проблема с туннелем: подписка не активна."
        case .unknown:
            return "Проблема с туннелем. Пробуем восстановить соединение."
        }
    }
}

private func connectProbe(host: String, port: UInt16, started: Date) async -> VpnAutopilotProbeResult {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: .tcp)
        let queue = DispatchQueue(label: "app.vex.vpn.native.endpoint-probe")
        let completion = EndpointProbeCompletion()
        let finish: @Sendable (VpnAutopilotProbeResult) -> Void = { result in
            guard completion.markFinished() else { return }
            connection.cancel()
            continuation.resume(returning: result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(VpnAutopilotProbeResult(dnsOk: true, endpointLatencyMs: Date().timeIntervalSince(started) * 1000))
            case .failed(let error):
                let message = String(describing: error)
                finish(VpnAutopilotProbeResult(dnsOk: !message.localizedCaseInsensitiveContains("dns"), endpointLatencyMs: nil, endpointProbeError: message))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

private final class EndpointProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

struct VpnAutopilotProbeResult: Equatable {
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

struct VpnAutopilotAssessment: Equatable {
    var cause: VpnAutopilotCause
    var canFailover: Bool
    var diagnosticStatus: String
    var userMessage: String
    var samples: [String: String]
}

enum VpnAutopilotCause: String, Equatable {
    case dns
    case keyOrProfile = "key_or_profile"
    case network
    case permission
    case server
    case subscription
    case unknown
}

enum NativeTunnelHealthReason: String, Equatable {
    case deviceUsageDegraded = "device_usage_degraded"
    case leakBlocking = "leak_blocking"
    case localStatusDisconnected = "local_status_disconnected"
    case localStatusError = "local_status_error"
    case staleLocalHandshake = "stale_local_handshake"
}

private struct ParsedEndpoint {
    var host: String
    var port: UInt16

    init?(_ endpoint: String?) {
        guard var value = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let suffix = value[value.index(after: close)...]
            port = UInt16(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) ?? 443
            return
        }
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount == 1, let separator = value.lastIndex(of: ":") {
            host = String(value[..<separator])
            port = UInt16(value[value.index(after: separator)...]) ?? 443
            return
        }
        if colonCount > 1 {
            value = "[\(value)]"
        }
        host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        port = 443
    }
}
