import Foundation
import Testing
@testable import VEXNativeMac

struct DynamicRouteEngineTests {
    @Test
    func ordersDirectThenRelayAndKeepsSuccessfulRelayStickyDuringHold() throws {
        let defaults = try makeDefaults()
        let engine = DynamicRouteEngine(defaults: defaults, stateKey: "state", policyKey: "policy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tunnel = makeTunnel()
        let policy = makePolicy(now: now)

        #expect(engine.orderedCandidates(for: tunnel, policy: policy, now: now).map(\.pathId) == ["direct:de-awg3", "ru-timeweb:55443"])
        let relay = try #require(policy.candidates.first { $0.pathId == "ru-timeweb:55443" })
        engine.recordSuccess(relay, policy: policy, now: now)

        #expect(engine.orderedCandidates(for: tunnel, policy: policy, now: now.addingTimeInterval(30)).first?.pathId == "ru-timeweb:55443")
        #expect(engine.orderedCandidates(for: tunnel, policy: policy, now: now.addingTimeInterval(121)).first?.pathId == "direct:de-awg3")
    }

    @Test
    func neverRoutesAnOlderProfileThroughAWG3Candidates() throws {
        let engine = DynamicRouteEngine(defaults: try makeDefaults(), stateKey: "state", policyKey: "policy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var oldTunnel = makeTunnel()
        oldTunnel.config = oldTunnel.config.replacingOccurrences(of: "HeaderProtectionKey = test\n", with: "")
        oldTunnel.awgVersion = 2
        #expect(engine.orderedCandidates(for: oldTunnel, policy: makePolicy(now: now), now: now).isEmpty)
    }

    @Test
    func quarantinesRouteAfterFailureThreshold() throws {
        let defaults = try makeDefaults()
        let engine = DynamicRouteEngine(defaults: defaults, stateKey: "state", policyKey: "policy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tunnel = makeTunnel()
        let policy = makePolicy(now: now)
        let direct = try #require(policy.candidates.first { $0.pathId == "direct:de-awg3" })

        engine.recordFailure(direct, policy: policy, now: now)
        #expect(engine.orderedCandidates(for: tunnel, policy: policy, now: now.addingTimeInterval(1)).contains { $0.id == direct.id })
        engine.recordFailure(direct, policy: policy, now: now.addingTimeInterval(2))
        #expect(!engine.orderedCandidates(for: tunnel, policy: policy, now: now.addingTimeInterval(3)).contains { $0.id == direct.id })
        #expect(engine.orderedCandidates(for: tunnel, policy: policy, now: now.addingTimeInterval(33)).contains { $0.id == direct.id })
    }

    @Test
    func usesUnexpiredCachedPolicyWhenApiIsUnavailable() throws {
        let defaults = try makeDefaults()
        let engine = DynamicRouteEngine(defaults: defaults, stateKey: "state", policyKey: "policy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = makePolicy(now: now)
        engine.cache(policy: policy)

        #expect(engine.cachedPolicy(now: now.addingTimeInterval(60))?.policyVersion == policy.policyVersion)
        #expect(engine.cachedPolicy(now: now.addingTimeInterval(700)) == nil)
    }

    @Test
    func candidateLimitPreservesIndependentFailureDomains() throws {
        let defaults = try makeDefaults()
        let engine = DynamicRouteEngine(defaults: defaults, stateKey: "state", policyKey: "policy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tunnel = makeTunnel()
        var policy = makePolicy(now: now)
        policy.probe.maxCandidates = 3
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))
        policy.candidates.append(
            ResilienceConnectionCandidate(
                id: "candidate-relay-same-domain", pathId: "ru-timeweb:55444", pathKind: "relay", entryNodeId: "ru-timeweb",
                failureDomain: "asn:9123", priority: 90, deviceId: "device-1", protocolName: "amneziawg",
                locationId: "de", nodeId: "de-awg3", endpoint: "201.34.134.96:55444",
                healthScore: 100, expiresAt: expiry
            )
        )
        policy.candidates.append(
            ResilienceConnectionCandidate(
                id: "candidate-relay-independent", pathId: "edge-b:55443", pathKind: "relay", entryNodeId: "edge-b",
                failureDomain: "asn:64501", priority: 70, deviceId: "device-1", protocolName: "amneziawg",
                locationId: "de", nodeId: "de-awg3", endpoint: "203.0.113.10:55443",
                healthScore: 100, expiresAt: expiry
            )
        )

        let selected = engine.orderedCandidates(for: tunnel, policy: policy, now: now)
        #expect(selected.count == 3)
        #expect(selected.first?.pathId == "direct:de-awg3")
        #expect(selected.contains { $0.pathId == "ru-timeweb:55444" })
        #expect(selected.contains { $0.pathId == "edge-b:55443" })
        #expect(!selected.contains { $0.pathId == "ru-timeweb:55443" })
        #expect(Set(selected.compactMap(\.entryNodeId)).count == 3)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "DynamicRouteEngineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeTunnel() -> PreparedTunnel {
        PreparedTunnel(
            device: VpnDevice(
                id: "device-1", name: "Mac", status: "active", assignedIpv4: nil,
                nodeId: "de-awg3", protocol: "amneziawg", protocolLabel: nil,
                endpoint: "94.141.160.212:51821", latencyMs: nil, publicKey: nil,
                provisioningMode: nil, clientKeyOwnership: nil, externalDeviceId: nil,
                platform: nil, appVersion: nil, pushProvider: nil, hasPushToken: nil
            ),
            config: "[Interface]\nPrivateKey = test\n[Peer]\nHeaderProtectionKey = test\nEndpoint = 94.141.160.212:51821\n",
            locationId: "de", profileVersion: 1, routingMode: .fullTunnel,
            bypassRegion: nil, bypassRangesCount: 0, bypassDomainsCount: 0,
            routingPolicyVersion: "test", rotationRequired: false
        )
    }

    private func makePolicy(now: Date) -> ResiliencePolicy {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: now.addingTimeInterval(600))
        let direct = ResilienceConnectionCandidate(
            id: "candidate-direct", pathId: "direct:de-awg3", pathKind: "direct", entryNodeId: "de-awg3",
            failureDomain: nil, priority: 100, deviceId: "device-1", protocolName: "amneziawg",
            locationId: "de", nodeId: "de-awg3", endpoint: "94.141.160.212:51821",
            healthScore: 100, expiresAt: expiry
        )
        let relay = ResilienceConnectionCandidate(
            id: "candidate-relay", pathId: "ru-timeweb:55443", pathKind: "relay", entryNodeId: "ru-timeweb",
            failureDomain: "asn:9123", priority: 80, deviceId: "device-1", protocolName: "amneziawg",
            locationId: "de", nodeId: "de-awg3", endpoint: "201.34.134.96:55443",
            healthScore: 100, expiresAt: expiry
        )
        return ResiliencePolicy(
            policyVersion: "test-v1",
            generatedAt: formatter.string(from: now),
            expiresAt: expiry,
            signature: ResiliencePolicySignature(status: "signed", alg: "Ed25519", keyId: "test", value: "sig", signedAt: formatter.string(from: now)),
            probe: ResilienceProbePolicy(
                connectTimeoutMs: 2_500, maxCandidates: 3, failureThreshold: 2,
                recoveryThreshold: 2, quarantineMs: 30_000, failbackHoldMs: 120_000,
                checks: ["tunnel"]
            ),
            candidates: [relay, direct]
        )
    }
}
