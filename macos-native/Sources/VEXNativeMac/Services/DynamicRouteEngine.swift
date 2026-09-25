import Foundation

final class DynamicRouteEngine {
    private struct RouteState: Codable {
        var consecutiveFailures = 0
        var consecutiveSuccesses = 0
        var quarantineUntil: TimeInterval?
        var lastSelectedAt: TimeInterval?
        var lastSuccessAt: TimeInterval?
    }

    private struct StoredState: Codable {
        var routes: [String: RouteState] = [:]
        var preferredPathByDevice: [String: String] = [:]
    }

    private let defaults: UserDefaults
    private let stateKey: String
    private let policyKey: String
    private var state: StoredState

    init(
        defaults: UserDefaults = .standard,
        stateKey: String = "native.dynamicRouteState.v1",
        policyKey: String = "native.resiliencePolicy.v1"
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.policyKey = policyKey
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            state = decoded
        } else {
            state = StoredState()
        }
    }

    func cache(policy: ResiliencePolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: policyKey)
    }

    func cachedPolicy(now: Date = Date()) -> ResiliencePolicy? {
        guard let data = defaults.data(forKey: policyKey),
              let policy = try? JSONDecoder().decode(ResiliencePolicy.self, from: data),
              let expiresAt = Self.parseISO8601(policy.expiresAt),
              expiresAt > now else {
            return nil
        }
        return policy
    }

    func orderedCandidates(
        for tunnel: PreparedTunnel,
        policy: ResiliencePolicy,
        now: Date = Date()
    ) -> [ResilienceConnectionCandidate] {
        guard tunnel.awgVersion >= 3, tunnel.config.range(
            of: #"(?m)^HeaderProtectionKey\s*=\s*\S+"#,
            options: .regularExpression
        ) != nil else { return [] }
        let deviceID = tunnel.device.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationID = tunnel.locationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nodeID = tunnel.device.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let protocolName = tunnel.device.protocol?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nowValue = now.timeIntervalSince1970
        let preferredPathID = state.preferredPathByDevice[deviceID]
        let failbackHold = TimeInterval(max(policy.probe.failbackHoldMs ?? 120_000, 0)) / 1000

        var candidates = policy.candidates.filter { candidate in
            guard candidate.deviceId == deviceID,
                  candidate.locationId.lowercased() == locationID,
                  !candidate.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if let nodeID, !nodeID.isEmpty, candidate.nodeId.lowercased() != nodeID {
                return false
            }
            if let protocolName, !protocolName.isEmpty, candidate.protocolName.lowercased() != protocolName {
                return false
            }
            guard let candidateExpiry = Self.parseISO8601(candidate.expiresAt), candidateExpiry > now else {
                return false
            }
            if let quarantineUntil = state.routes[candidate.id]?.quarantineUntil, quarantineUntil > nowValue {
                return false
            }
            return true
        }

        let stickyPreferred: String? = {
            guard let preferredPathID,
                  let preferred = candidates.first(where: { Self.pathID(for: $0) == preferredPathID }),
                  let lastSuccessAt = state.routes[preferred.id]?.lastSuccessAt,
                  nowValue - lastSuccessAt < failbackHold else {
                return nil
            }
            return preferredPathID
        }()

        candidates.sort { left, right in
            let leftPath = Self.pathID(for: left)
            let rightPath = Self.pathID(for: right)
            if let stickyPreferred, leftPath != rightPath {
                if leftPath == stickyPreferred { return true }
                if rightPath == stickyPreferred { return false }
            }
            let leftPriority = left.priority ?? 0
            let rightPriority = right.priority ?? 0
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            if left.healthScore != right.healthScore { return left.healthScore > right.healthScore }
            return left.id < right.id
        }

        let maxCandidates = max(policy.probe.maxCandidates, 1)
        guard candidates.count > maxCandidates else {
            return candidates
        }

        // Preserve failure-domain diversity before filling the remaining slots.
        // Once multiple independent ingress providers are qualified, a simple
        // prefix can otherwise discard the only working alternate path.
        var selected: [ResilienceConnectionCandidate] = []
        var selectedIDs = Set<String>()
        var seenDomains = Set<String>()

        for candidate in candidates {
            let domain = Self.failureDomainKey(for: candidate)
            guard !seenDomains.contains(domain) else { continue }
            selected.append(candidate)
            selectedIDs.insert(candidate.id)
            seenDomains.insert(domain)
            if selected.count == maxCandidates { return selected }
        }

        for candidate in candidates where !selectedIDs.contains(candidate.id) {
            selected.append(candidate)
            if selected.count == maxCandidates { break }
        }
        return selected
    }

    func recordFailure(_ candidate: ResilienceConnectionCandidate, policy: ResiliencePolicy, now: Date = Date()) {
        var routeState = state.routes[candidate.id] ?? RouteState()
        routeState.consecutiveFailures += 1
        routeState.consecutiveSuccesses = 0
        routeState.lastSelectedAt = now.timeIntervalSince1970
        let failureThreshold = max(policy.probe.failureThreshold ?? 2, 1)
        if routeState.consecutiveFailures >= failureThreshold {
            let quarantine = TimeInterval(max(policy.probe.quarantineMs ?? 30_000, 0)) / 1000
            routeState.quarantineUntil = now.addingTimeInterval(quarantine).timeIntervalSince1970
            let pathID = Self.pathID(for: candidate)
            if state.preferredPathByDevice[candidate.deviceId] == pathID {
                state.preferredPathByDevice.removeValue(forKey: candidate.deviceId)
            }
        }
        state.routes[candidate.id] = routeState
        persistState()
    }

    func recordSuccess(_ candidate: ResilienceConnectionCandidate, policy: ResiliencePolicy, now: Date = Date()) {
        var routeState = state.routes[candidate.id] ?? RouteState()
        routeState.consecutiveFailures = 0
        routeState.consecutiveSuccesses += 1
        routeState.quarantineUntil = nil
        routeState.lastSelectedAt = now.timeIntervalSince1970
        routeState.lastSuccessAt = now.timeIntervalSince1970
        state.routes[candidate.id] = routeState
        state.preferredPathByDevice[candidate.deviceId] = Self.pathID(for: candidate)
        persistState()
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    private static func pathID(for candidate: ResilienceConnectionCandidate) -> String {
        let pathID = candidate.pathId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pathID.isEmpty ? candidate.id : pathID
    }

    private static func failureDomainKey(for candidate: ResilienceConnectionCandidate) -> String {
        let failureDomain = candidate.failureDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !failureDomain.isEmpty { return "failure-domain:\(failureDomain)" }
        let entryNodeID = candidate.entryNodeId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !entryNodeID.isEmpty { return "entry:\(entryNodeID)" }
        return "endpoint:\(candidate.endpoint.lowercased())"
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
