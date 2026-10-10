import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VEXNativeMac

@MainActor
final class VPNAccountIdentityTests: XCTestCase {
    func testAccountBRegistersItsOwnInstallationAndKeyWithoutChangingLegacyA() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network()
        let tunnel = try await fixture.resolve("account-b", network: network)
        let scope = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        let pair = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertNotEqual(scope.installationId, Fixture.legacyID)
        XCTAssertEqual(scope.externalDeviceId, scope.installationId)
        XCTAssertNotEqual(pair.publicKey, Fixture.legacyKey.publicKey)
        XCTAssertEqual(tunnel.device.id, "device-account-b")
        XCTAssertEqual(network.registrations.map(\.installation), [scope.installationId])
        XCTAssertEqual(fixture.files.string(for: "vex.auth.device_id"), Fixture.legacyID)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertFalse(network.paths.contains { $0.contains("replace-binding") || $0.contains("delete") })
    }

    func testLegacyOwnerMigratesWithoutRegisteringASecondDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        let tunnel = try await fixture.resolve("account-a", network: network)
        let scope = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertEqual(scope, VEXVpnDeviceScope(installationId: Fixture.legacyID, externalDeviceId: Fixture.legacyID))
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-a"), Fixture.legacyKey)
        XCTAssertEqual(tunnel.device.id, "device-account-a")
        XCTAssertEqual(network.registrations.map(\.installation), [Fixture.legacyID])
        XCTAssertEqual(network.paths, ["/v1/devices", "/v1/devices/identity-challenge", "/v1/devices/register", "/v1/vpn/profile"])
        XCTAssertEqual(network.deviceCount(account: "account-a"), 1)
    }

    func testReturningToLegacyAAfterBReusesBothAccountMappings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        _ = try await fixture.resolve("account-b", network: network)
        let b = try fixture.identities.scopedDeviceScope(accountUserId: "account-b")
        let bKey = try fixture.keys.existing(accountUserId: "account-b")
        _ = try await fixture.resolve("account-a", network: network)
        _ = try await fixture.resolve("account-b", network: network)
        XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: "account-b"), b)
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-b"), bKey)
        XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: "account-a")?.installationId, Fixture.legacyID)
        XCTAssertEqual(network.registrations.count, 2)
    }

    func testOwnedLegacyCollisionRepairsOnlyLogicalInstallationOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldB = try fixture.device("account-b", publicKey: Fixture.otherKey.publicKey, epoch: 6, appVersion: "old")
        let network = fixture.network(devices: ["account-b": [oldB]], conflicts: [(409, "conflict", "device_rebind_required")])
        let tunnel = try await fixture.resolve("account-b", network: network)
        let scope = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertEqual(tunnel.device.id, oldB.id)
        XCTAssertEqual(scope.externalDeviceId, Fixture.legacyID)
        XCTAssertNotEqual(scope.installationId, Fixture.legacyID)
        XCTAssertEqual(network.registrations.map(\.external), [Fixture.legacyID, Fixture.legacyID])
        XCTAssertEqual(network.registrations.map(\.installation), [Fixture.legacyID, scope.installationId])
        XCTAssertEqual(Set(network.registrations.map(\.idempotency)).count, 2)
        XCTAssertEqual(Set(network.registrations.map(\.challenge)).count, 2)
        XCTAssertEqual(network.rotationEpochs, [7])
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
        XCTAssertEqual(fixture.files.string(for: "vex.auth.device_id"), Fixture.legacyID)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
        _ = try await fixture.resolve("account-b", network: network)
        XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: "account-b"), scope)
        XCTAssertEqual(network.registrations.count, 2)
    }

    func testOtherRegistrationErrorsDoNotRewriteAnOwnedInstallation() async throws {
        for failure in [(409, "device_limit", "device limit reached"), (503, "unavailable", "temporarily unavailable"),
                        (409, "conflict", "different conflict")] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let old = try fixture.device("account-a", appVersion: "old")
            let network = fixture.network(devices: ["account-a": [old]], conflicts: [failure])
            do { _ = try await fixture.resolve("account-a", network: network); XCTFail("Registration should fail") }
            catch { XCTAssertTrue(error is VEXAPIError) }
            XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: "account-a")?.installationId, Fixture.legacyID)
            XCTAssertEqual(network.registrations.count, 1)
        }
    }

    func testHistoricalAccountsWithTheSameLegacyPublicKeyAcquireDistinctScopedKeys() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.device("account-a")
        let b = try fixture.device("account-b", appVersion: "old")
        let network = fixture.network(devices: ["account-a": [a], "account-b": [b]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b")
        _ = try await fixture.resolve("account-a", network: network)
        let aKey = try fixture.keys.existing(accountUserId: "account-a")
        _ = try await fixture.resolve("account-b", network: network)
        let bKey = try fixture.keys.existing(accountUserId: "account-b")
        XCTAssertEqual(aKey, Fixture.legacyKey)
        XCTAssertNotEqual(aKey?.publicKey, bKey?.publicKey)
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-a"), aKey)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
        XCTAssertEqual(network.rotationEpochs, [8])
        XCTAssertEqual(network.deviceCount(account: "account-a"), 1)
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
    }

    func testBFirstWithCurrentLegacyMetadataSeparatesItsKeyBeforeAHasMigrated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.device("account-a")
        let b = try fixture.device("account-b")
        XCTAssertNil(fixture.files.string(for: "vex.wireguard.keypair.v1.legacy_owner.v1"))
        let network = fixture.network(devices: ["account-a": [a], "account-b": [b]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b")
        let tunnel = try await fixture.resolve("account-b", network: network)
        let scoped = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        let scope = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertNotEqual(scoped.publicKey, Fixture.legacyKey.publicKey)
        XCTAssertEqual(scoped.keyEpoch, 8)
        XCTAssertEqual(tunnel.device.publicKey, scoped.publicKey)
        XCTAssertNotEqual(scope.installationId, Fixture.legacyID)
        XCTAssertEqual(scope.externalDeviceId, Fixture.legacyID)
        XCTAssertFalse(scope.registrationConfirmationPending)
        XCTAssertEqual(network.registrations.map(\.account), ["account-b", "account-b"])
        XCTAssertEqual(network.rotationEpochs, [8])
        XCTAssertEqual(network.publicKey(account: "account-a"), Fixture.legacyKey.publicKey)
        XCTAssertEqual(network.publicKey(account: "account-b"), scoped.publicKey)
        XCTAssertEqual(network.deviceCount(account: "account-a"), 1)
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertEqual(fixture.files.string(for: "vex.auth.device_id"), Fixture.legacyID)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
        XCTAssertEqual(fixture.files.string(for: "vex.wireguard.keypair.v1.legacy_owner.v1"), "account-b")
    }

    func testFailedLegacyChallengeKeepsConfirmationPendingWithoutUnsignedRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]], challengeFailures: 1)
        do { _ = try await fixture.resolve("account-a", network: network); XCTFail("A pending migration requires a signed challenge") }
        catch { XCTAssertTrue(error is VEXAPIError) }
        let pending = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertTrue(pending.registrationConfirmationPending)
        XCTAssertEqual(pending.installationId, Fixture.legacyID)
        XCTAssertTrue(network.registrations.isEmpty)
        XCTAssertFalse(network.paths.contains("/v1/vpn/profile"))
        _ = try await fixture.resolve("account-a", network: network)
        XCTAssertFalse(try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-a")).registrationConfirmationPending)
        XCTAssertEqual(network.registrations.map(\.installation), [Fixture.legacyID])
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-a"), Fixture.legacyKey)
        XCTAssertEqual(network.deviceCount(account: "account-a"), 1)
    }

    func testFailedCollisionRotationKeepsPendingAndReusesFreshScopedKeyOnRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")], "account-b": [try fixture.device("account-b")]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b", rotationFailures: 1)
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Failed owner rotation cannot complete migration") }
        catch { XCTAssertTrue(error is VEXAPIError) }
        let pending = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        let fresh = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertTrue(pending.registrationConfirmationPending)
        XCTAssertNotEqual(pending.installationId, Fixture.legacyID)
        XCTAssertNotEqual(fresh.publicKey, Fixture.legacyKey.publicKey)
        XCTAssertFalse(network.paths.contains("/v1/vpn/profile"))
        _ = try await fixture.resolve("account-b", network: network)
        let confirmed = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertFalse(confirmed.registrationConfirmationPending)
        XCTAssertEqual(confirmed.installationId, pending.installationId)
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-b"), fresh)
        XCTAssertEqual(network.rotationEpochs, [8, 8])
        XCTAssertEqual(network.registrations.map(\.installation), [Fixture.legacyID, pending.installationId, pending.installationId])
        XCTAssertEqual(network.publicKey(account: "account-a"), Fixture.legacyKey.publicKey)
        XCTAssertEqual(network.publicKey(account: "account-b"), fresh.publicKey)
    }

    func testLostRotationReplyAndRestartRetainTheFreshPrivateKeyWithoutRotatingAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")], "account-b": [try fixture.device("account-b")]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b", lostRotationReplies: 1)
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Lost owner rotation reply must leave confirmation pending") }
        catch { guard case VEXAPIError.requestTimeout = error else { return XCTFail("Lost reply must surface the normalized request timeout: \(error)") } }
        let pending = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        let fresh = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertTrue(pending.registrationConfirmationPending)
        XCTAssertEqual(network.publicKey(account: "account-b"), fresh.publicKey)
        XCTAssertFalse(network.paths.contains("/v1/vpn/profile"))
        // Fixture accessors construct new stores and a new service from disk.
        _ = try await fixture.resolve("account-b", network: network)
        XCTAssertEqual(try fixture.keys.existing(accountUserId: "account-b"), fresh)
        XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: "account-b")?.installationId, pending.installationId)
        XCTAssertFalse(try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b")).registrationConfirmationPending)
        XCTAssertEqual(network.rotationEpochs, [8])
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
        XCTAssertEqual(network.publicKey(account: "account-a"), Fixture.legacyKey.publicKey)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
    }

    func testFreshOwnedLegacyCacheCannotBypassPendingBindingConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let b = try fixture.device("account-b")
        let config = "[Interface]\nPrivateKey = \(Fixture.legacyKey.privateKey)\nAddress = 192.0.2.2/32\n[Peer]\nPublicKey = fixture-peer\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n"
        let record = PreparedTunnelCacheRecord(tunnel: PreparedTunnel(device: b, config: config, locationId: "de",
            profileVersion: 123, routingMode: .fullTunnel, bypassRegion: nil, bypassRangesCount: 0,
            bypassDomainsCount: 0, routingPolicyVersion: VEXAppInfo.routingPolicyVersion, rotationRequired: false),
            accountUserId: "account-b", localKeyEpoch: Fixture.legacyKey.keyEpoch)
        XCTAssertTrue(VPNProfileCacheIdentity.canReuse(record, accountUserId: "account-b", installationId: Fixture.legacyID,
            keyPair: Fixture.legacyKey, locationId: "de", routingMode: .fullTunnel))
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")], "account-b": [b]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b")
        let service = fixture.service(network)
        let tunnel = try await service.resolveProfile(accessToken: "token-account-b", userId: "account-b", locationId: "de",
            routingMode: .fullTunnel, forceRefresh: false, writeHelperConfig: false,
            prevalidatedEntitlement: Entitlement(active: true, vpnAccess: true))
        XCTAssertNotEqual(tunnel.device.publicKey, Fixture.legacyKey.publicKey)
        XCTAssertEqual(network.registrations.count, 2)
        XCTAssertEqual(network.rotationEpochs, [8])
        let completedRequests = network.paths.count
        _ = try await service.resolveProfile(accessToken: "token-account-b", userId: "account-b", locationId: "de",
            routingMode: .fullTunnel, forceRefresh: false, writeHelperConfig: false,
            prevalidatedEntitlement: Entitlement(active: true, vpnAccess: true))
        XCTAssertEqual(network.paths.count, completedRequests, "Confirmed fresh cache should keep its zero-request fast path")
    }

    func testLostIndexedRegistrationAndPSKAdvanceReuseTheInstallationAndPrivateKeyOnRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")], "account-b": [try fixture.device("account-b")]],
            conflicts: [(409, "conflict", "device_rebind_required")], conflictAccount: "account-b",
            lostRegistrationReplies: 1, recreateLegacyOnRepairRegistration: true)
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Lost indexed registration reply must retain pending state") }
        catch { guard case VEXAPIError.requestTimeout = error else { return XCTFail("Expected normalized registration timeout: \(error)") } }
        let pending = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        let saved = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertTrue(pending.registrationConfirmationPending)
        XCTAssertEqual(saved.keyEpoch, 8)
        XCTAssertEqual(network.publicKey(account: "account-b"), saved.publicKey)
        network.advancePSKEpoch(account: "account-b", epoch: 9)
        _ = try await fixture.resolve("account-b", network: network)
        let confirmed = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        let current = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertEqual(confirmed.installationId, pending.installationId)
        XCTAssertEqual(confirmed.externalDeviceId, Fixture.legacyID)
        XCTAssertFalse(confirmed.registrationConfirmationPending)
        XCTAssertEqual(current.privateKey, saved.privateKey)
        XCTAssertEqual(current.publicKey, saved.publicKey)
        XCTAssertEqual(current.keyEpoch, 9)
        XCTAssertEqual(network.registrations.map(\.installation), [Fixture.legacyID, pending.installationId, pending.installationId])
        XCTAssertTrue(network.rotationEpochs.isEmpty)
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
        XCTAssertEqual(network.publicKey(account: "account-a"), Fixture.legacyKey.publicKey)
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
    }

    func testExactCollisionWithoutLiveOwnedLegacyProofCannotRewriteIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(conflicts: [(409, "conflict", "device_rebind_required")])
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("An unowned binding must fail") }
        catch { XCTAssertTrue(error is VEXAPIError) }
        let scope = try XCTUnwrap(fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertNotEqual(scope.installationId, Fixture.legacyID)
        XCTAssertEqual(network.registrations.map(\.installation), [scope.installationId])
    }

    func testFailedAuthenticatedLookupDoesNotAllocateAccountIdentityOrKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(lookupFailure: 401)
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Lookup failure must stop migration") }
        catch { XCTAssertTrue(error.isUnauthorizedAPIError) }
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertTrue(network.registrations.isEmpty)
    }

    func testForeignOwnerInAuthenticatedLookupCannotBeAdopted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-b": [try fixture.device("account-a")]])
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Foreign owner must fail") }
        catch VPNProfileError.profileIdentityMismatch { }
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-b"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertTrue(network.registrations.isEmpty)
    }

    func testExistingMappingWithMissingOrCorruptKeyFailsClosed() async throws {
        var hugeEpoch = Fixture.legacyKey
        hugeEpoch.keyEpoch = Int.max
        let hugePayload = String(data: try JSONEncoder().encode(hugeEpoch), encoding: .utf8)
        var mismatched = Fixture.legacyKey
        mismatched.publicKey = Fixture.otherKey.publicKey
        let mismatchedPayload = String(data: try JSONEncoder().encode(mismatched), encoding: .utf8)
        for payload in [nil, "{}", "{\"privateKey\":\"bad\",\"publicKey\":\"bad\",\"keyEpoch\":1}", hugePayload, mismatchedPayload] as [String?] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = try fixture.identities.getOrCreateDeviceScope(accountUserId: "account-b")
            if let payload { try fixture.files.setString(payload, for: VPNAccountScope.storageKey("vex.wireguard.keypair.v1", accountUserId: "account-b")) }
            let network = fixture.network()
            do { _ = try await fixture.resolve("account-b", network: network); XCTFail("Missing/corrupt scoped key must fail") }
            catch { }
            XCTAssertTrue(network.paths.isEmpty)
            XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
        }
    }

    func testMalformedLegacyIdentifierDoesNotCreateASecondIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.files.setString("invalid-installation", for: "vex.auth.device_id")
        let network = fixture.network()
        do { _ = try await fixture.resolve("account-a", network: network); XCTFail("Malformed stored identity must fail") }
        catch { }
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertTrue(network.paths.isEmpty)
    }

    func testUnreadableScopedStorageIsNotTreatedAsAMissingInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scopedKey = try VPNAccountScope.storageKey("vex.auth.device_id", accountUserId: "account-b")
        let fileName = scopedKey.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let blocked = fixture.directory.appendingPathComponent("sensitive/\(fileName).json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let network = fixture.network()
        do { _ = try await fixture.resolve("account-b", network: network); XCTFail("An unreadable store must not allocate an identity") }
        catch { }
        XCTAssertTrue(network.paths.isEmpty)
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
    }

    func testCorruptLegacyKeyOwnerMarkerCannotCopyOrRegenerateAKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.files.setString("", for: "vex.wireguard.keypair.v1.legacy_owner.v1")
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        do { _ = try await fixture.resolve("account-a", network: network); XCTFail("A corrupt legacy owner marker must stop migration") }
        catch { }
        XCTAssertEqual(network.paths, ["/v1/devices"])
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
    }

    func testAccountNamespacesRemainDistinctOnCaseInsensitiveVolumes() throws {
        let users = ["A", "a", "_-", "ō"]
        let storage = try users.map { try VPNAccountScope.storageKey("vex.auth.device_id", accountUserId: $0).lowercased() }
        XCTAssertEqual(Set(storage).count, users.count)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scopes = try users.map { try fixture.identities.getOrCreateDeviceScope(accountUserId: $0) }
        XCTAssertEqual(Set(scopes.map(\.installationId)).count, users.count)
        for (user, scope) in zip(users, scopes) { XCTAssertEqual(try fixture.identities.scopedDeviceScope(accountUserId: user), scope) }
    }

    func testLogoutAndBWhileLegacyLookupIsSuspendedCannotPersistOrRegisterA() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = expectation(description: "A legacy lookup started")
        let gate = AccountGate()
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        let service = fixture.service(network) { request in
            if request.url?.path == "/v1/devices", request.value(forHTTPHeaderField: "Authorization") == "Bearer token-account-a" {
                started.fulfill(); await gate.wait()
            }
        }
        var currentAccount = "account-a"
        let old = Task { try await fixture.resolve("account-a", service: service, shouldPersist: { currentAccount == "account-a" }) }
        await fulfillment(of: [started], timeout: 2)
        currentAccount = "account-b"
        _ = try await fixture.resolve("account-b", service: service, shouldPersist: { currentAccount == "account-b" })
        await gate.release()
        do { _ = try await old.value; XCTFail("Retired A lookup must cancel") } catch is CancellationError { }
        XCTAssertNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertEqual(network.registrations.map(\.account), ["account-b"])
        XCTAssertEqual(fixture.files.string(for: "vex.auth.device_id"), Fixture.legacyID)
    }

    func testLateAProfileAfterBDoesNotWriteCacheOrHelperConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.keys.save(Fixture.legacyKey, accountUserId: "account-a")
        _ = try fixture.identities.getOrCreateDeviceScope(accountUserId: "account-a", adoptingLegacyId: Fixture.legacyID)
        let started = expectation(description: "A profile suspended")
        let gate = AccountGate()
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        let service = fixture.service(network) { request in
            if request.url?.path == "/v1/vpn/profile", request.value(forHTTPHeaderField: "Authorization") == "Bearer token-account-a" {
                started.fulfill(); await gate.wait()
            }
        }
        var currentAccount = "account-a"
        let old = Task { try await service.resolveProfile(accessToken: "token-account-a", userId: "account-a", locationId: "de",
            routingMode: .fullTunnel, writeHelperConfig: true, prevalidatedEntitlement: Entitlement(active: true, vpnAccess: true),
            shouldPersist: { currentAccount == "account-a" }) }
        await fulfillment(of: [started], timeout: 2)
        currentAccount = "account-b"
        _ = try await fixture.resolve("account-b", service: service)
        await gate.release()
        do { _ = try await old.value; XCTFail("Retired A response must cancel") } catch is CancellationError { }
        XCTAssertNil(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"))
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-b")?.device.userId, "account-b")
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testLogoutAndBWhileIdentityChallengeIsSuspendedCannotRegisterA() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = expectation(description: "A identity challenge suspended")
        let gate = AccountGate()
        let network = fixture.network()
        let service = fixture.service(network) { request in
            if request.url?.path == "/v1/devices/identity-challenge", request.value(forHTTPHeaderField: "Authorization") == "Bearer token-account-a" {
                started.fulfill(); await gate.wait()
            }
        }
        var currentAccount = "account-a"
        let old = Task { try await fixture.resolve("account-a", service: service, shouldPersist: { currentAccount == "account-a" }) }
        await fulfillment(of: [started], timeout: 2)
        currentAccount = "account-b"
        _ = try await fixture.resolve("account-b", service: service, shouldPersist: { currentAccount == "account-b" })
        await gate.release()
        do { _ = try await old.value; XCTFail("Retired A challenge must not register") } catch is CancellationError { }
        XCTAssertNotNil(try fixture.identities.scopedDeviceScope(accountUserId: "account-a"))
        XCTAssertNotNil(try fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertEqual(network.registrations.map(\.account), ["account-b"])
        XCTAssertEqual(network.deviceCount(account: "account-a"), 0)
        XCTAssertNil(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"))
    }

    func testExplicitRotationUsesTheLiveServerEpochAndOnlyTheCurrentAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let network = fixture.network(devices: ["account-a": [try fixture.device("account-a")]])
        let service = fixture.service(network)
        let current = try await fixture.resolve("account-a", service: service)
        network.replaceDevice(account: "account-a", device: try fixture.device("account-a", epoch: 9))
        let rotated = try await service.rotateKey(accessToken: "token-account-a", userId: "account-a",
            currentTunnel: current, writeHelperConfig: false)
        let scoped = try XCTUnwrap(fixture.keys.existing(accountUserId: "account-a"))
        XCTAssertEqual(scoped.keyEpoch, 10)
        XCTAssertNotEqual(scoped.publicKey, Fixture.legacyKey.publicKey)
        XCTAssertEqual(rotated?.device.keyEpoch, 10)
        XCTAssertEqual(network.rotationEpochs, [10])
        XCTAssertTrue(network.paths.contains("/v1/billing/entitlement"))
        XCTAssertEqual(network.deviceCount(account: "account-a"), 1)
        XCTAssertNil(try fixture.keys.existing(accountUserId: "account-b"))
        XCTAssertEqual(try fixture.keys.getOrCreate(), Fixture.legacyKey)
    }

    func testConcurrentFirstMappingUsesOnePersistedInstallationAndDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lookups = expectation(description: "Both first lookups started")
        lookups.expectedFulfillmentCount = 2
        let gate = AccountGate()
        let network = fixture.network()
        let service = fixture.service(network) { request in
            if request.url?.path == "/v1/devices" { lookups.fulfill(); await gate.wait() }
        }
        let first = Task { try await fixture.resolve("account-b", service: service) }
        let second = Task { try await fixture.resolve("account-b", service: service) }
        await fulfillment(of: [lookups], timeout: 2)
        await gate.release()
        let tunnels = try await [first.value, second.value]
        XCTAssertEqual(Set(tunnels.map { $0.device.id }).count, 1)
        XCTAssertEqual(Set(network.registrations.map(\.installation)).count, 1)
        XCTAssertEqual(network.deviceCount(account: "account-b"), 1)
    }

    private struct Fixture {
        static let legacyID = "vexd_legacy-account-a"
        static let legacyKey = WireGuardKeyPair(privateKey: "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=",
            publicKey: "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=", keyEpoch: 7)
        static let otherKey = WireGuardKeyPair(privateKey: "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=",
            publicKey: "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=", keyEpoch: 6)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VPNAccountIdentity-\(UUID().uuidString)")
        let keychain = MemoryVpnIdentityKeychain()
        var files: AppSensitiveFileStore { AppSensitiveFileStore(directoryURL: directory.appendingPathComponent("sensitive")) }
        var identities: VEXDeviceIdentityStore { VEXDeviceIdentityStore(fileStore: files, nativeKeychain: keychain) }
        var keys: WireGuardKeyStore { WireGuardKeyStore(fileStore: files, nativeKeychain: keychain) }
        var cache: VPNProfileCache { VPNProfileCache(directoryURL: directory, helperConfigURL: directory.appendingPathComponent("helper/vex.conf")) }
        init() throws { try files.setString(Self.legacyID, for: "vex.auth.device_id"); try keys.save(Self.legacyKey) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func device(_ account: String, publicKey: String = legacyKey.publicKey, epoch: Int = 7,
                    appVersion: String = VEXAppInfo.version) throws -> VpnDevice {
            try JSONDecoder().decode(VpnDevice.self, from: JSONSerialization.data(withJSONObject: [
                "id": "device-\(account)", "user_id": account, "status": "active", "protocol": "amneziawg",
                "provisioning_mode": "managed_native", "client_key_ownership": "client", "platform": "macos",
                "app_version": appVersion, "external_device_id": Self.legacyID, "assigned_ipv4": "192.0.2.2/32",
                "public_key": publicKey, "psk_epoch": epoch,
            ]))
        }
        func network(devices: [String: [VpnDevice]] = [:], conflicts: [(Int, String, String)] = [], lookupFailure: Int? = nil,
                     conflictAccount: String? = nil, challengeFailures: Int = 0, rotationFailures: Int = 0,
                     lostRotationReplies: Int = 0, lostRegistrationReplies: Int = 0,
                     recreateLegacyOnRepairRegistration: Bool = false) -> AccountNetwork {
            let keys = self.keys
            return AccountNetwork(devices: devices, conflicts: conflicts, lookupFailure: lookupFailure, conflictAccount: conflictAccount,
                challengeFailures: challengeFailures, rotationFailures: rotationFailures, lostRotationReplies: lostRotationReplies,
                lostRegistrationReplies: lostRegistrationReplies, recreateLegacyOnRepairRegistration: recreateLegacyOnRepairRegistration,
                key: { try keys.existing(accountUserId: $0) })
        }
        @MainActor func service(_ network: AccountNetwork, beforeRequest: (@Sendable (URLRequest) async -> Void)? = nil) -> VPNProfileService {
            var api = VEXAPIClient()
            api.baseURL = URL(string: "https://api.example.invalid")!
            api.transport.load = { request in await beforeRequest?(request); return try network.respond(to: request) }
            return VPNProfileService(api: api, identityStore: identities, keyStore: keys, cache: cache)
        }
        @MainActor func resolve(_ account: String, network: AccountNetwork) async throws -> PreparedTunnel {
            try await resolve(account, service: service(network))
        }
        @MainActor func resolve(_ account: String, service: VPNProfileService, shouldPersist: () -> Bool = { true }) async throws -> PreparedTunnel {
            try await service.resolveProfile(accessToken: "token-\(account)", userId: account, locationId: "de", routingMode: .fullTunnel,
                forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: Entitlement(active: true, vpnAccess: true),
                shouldPersist: shouldPersist)
        }
    }

    private final class AccountNetwork: @unchecked Sendable {
        struct Registration { var account: String; var external: String; var installation: String; var idempotency: String; var challenge: String }
        private let lock = NSLock()
        private var devices: [String: [VpnDevice]]
        private var failures: [(Int, String, String)]
        private let lookupFailure: Int?
        private let conflictAccount: String?
        private var challengeFailures: Int
        private var rotationFailures: Int
        private var lostRotationReplies: Int
        private var lostRegistrationReplies: Int
        private var recreateLegacyOnRepairRegistration: Bool
        private var indexedRegistrationKeys: [String: String] = [:]
        private let key: (String) throws -> WireGuardKeyPair?
        private var requests: [URLRequest] = []
        private var storedRegistrations: [Registration] = []
        private var storedEpochs: [Int] = []
        private var challenges = 0
        var registrations: [Registration] { withLock { storedRegistrations } }
        var paths: [String] { withLock { requests.compactMap { $0.url?.path } } }
        var rotationEpochs: [Int] { withLock { storedEpochs } }
        func deviceCount(account: String) -> Int { withLock { devices[account]?.count ?? 0 } }
        func publicKey(account: String) -> String? { withLock { devices[account]?.first?.publicKey } }
        func replaceDevice(account: String, device: VpnDevice) { withLock { devices[account] = [device] } }
        func advancePSKEpoch(account: String, epoch: Int) {
            withLock { guard var device = devices[account]?.first else { return }; device.keyEpoch = epoch; devices[account] = [device] }
        }
        init(devices: [String: [VpnDevice]], conflicts: [(Int, String, String)], lookupFailure: Int?, conflictAccount: String?,
             challengeFailures: Int, rotationFailures: Int, lostRotationReplies: Int, lostRegistrationReplies: Int,
             recreateLegacyOnRepairRegistration: Bool, key: @escaping (String) throws -> WireGuardKeyPair?) {
            self.devices = devices; failures = conflicts; self.lookupFailure = lookupFailure; self.conflictAccount = conflictAccount; self.key = key
            self.challengeFailures = challengeFailures; self.rotationFailures = rotationFailures
            self.lostRotationReplies = lostRotationReplies
            self.lostRegistrationReplies = lostRegistrationReplies
            self.recreateLegacyOnRepairRegistration = recreateLegacyOnRepairRegistration
        }
        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            try withLock {
                requests.append(request)
                let account = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer token-", with: "")
                let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                func response(_ object: Any, _ status: Int = 200) throws -> (Data, URLResponse) {
                    (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                switch request.url?.path {
                case "/v1/billing/entitlement":
                    return try response(["active": true, "vpn_access": true])
                case "/v1/devices":
                    if let lookupFailure { return try response(["code": "unauthorized", "message": "expired"], lookupFailure) }
                    return (try JSONEncoder().encode(devices[account] ?? []), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                case "/v1/devices/identity-challenge":
                    if challengeFailures > 0 {
                        challengeFailures -= 1
                        return try response(["code": "unavailable", "message": "challenge unavailable"], 503)
                    }
                    challenges += 1
                    return try response(["id": "challenge-\(challenges)", "nonce": "nonce-\(challenges)", "purpose": "register", "expires_at": "2099-01-01T00:00:00Z"])
                case "/v1/devices/register":
                    let external = body?["device_id"] as? String ?? ""
                    storedRegistrations.append(Registration(account: account, external: external,
                        installation: body?["installation_id"] as? String ?? "", idempotency: request.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
                        challenge: body?["identity_challenge_id"] as? String ?? ""))
                    if !failures.isEmpty, conflictAccount == nil || conflictAccount == account {
                        let failure = failures.removeFirst(); return try response(["code": failure.1, "message": failure.2], failure.0)
                    }
                    let installation = body?["installation_id"] as? String ?? ""
                    let idempotency = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
                    let recreate = recreateLegacyOnRepairRegistration && installation != external
                    if recreate { devices[account] = []; recreateLegacyOnRepairRegistration = false }
                    if var existing = devices[account]?.first(where: { $0.externalDeviceId == external }) {
                        if indexedRegistrationKeys[account] == idempotency,
                           existing.publicKey != body?["public_key"] as? String || existing.keyEpoch != body?["key_epoch"] as? Int {
                            return try response(["code": "conflict", "message": "device_rebind_required"], 409)
                        }
                        existing.appVersion = body?["app_version"] as? String
                        devices[account] = [existing]
                        return try response(["device": JSONSerialization.jsonObject(with: JSONEncoder().encode(existing))])
                    }
                    let object: [String: Any] = ["id": "device-\(account)\(recreate ? "-recreated" : "")", "user_id": account, "status": "active", "protocol": "amneziawg",
                        "provisioning_mode": "managed_native", "client_key_ownership": "client", "platform": "macos", "app_version": VEXAppInfo.version,
                        "external_device_id": external, "public_key": body?["public_key"] as? String ?? "", "psk_epoch": body?["key_epoch"] as? Int ?? 1,
                        "assigned_ipv4": "192.0.2.2/32"]
                    let created = try JSONDecoder().decode(VpnDevice.self, from: JSONSerialization.data(withJSONObject: object))
                    devices[account, default: []].append(created)
                    indexedRegistrationKeys[account] = idempotency
                    if lostRegistrationReplies > 0 { lostRegistrationReplies -= 1; throw URLError(.timedOut) }
                    return try response(["device": object])
                case "/v1/vpn/rotate-key":
                    guard var device = devices[account]?.first, let epoch = body?["key_epoch"] as? Int else { throw VEXAPIError.invalidResponse }
                    storedEpochs.append(epoch)
                    if rotationFailures > 0 {
                        rotationFailures -= 1
                        return try response(["code": "unavailable", "message": "rotation unavailable"], 503)
                    }
                    guard epoch == (device.keyEpoch ?? 0) + 1 else { return try response(["code": "conflict", "message": "key_epoch does not match next device epoch"], 409) }
                    device.publicKey = body?["public_key"] as? String; device.keyEpoch = epoch
                    devices[account] = [device]
                    if lostRotationReplies > 0 { lostRotationReplies -= 1; throw URLError(.timedOut) }
                    return try response(["device": JSONSerialization.jsonObject(with: JSONEncoder().encode(device))])
                case "/v1/vpn/profile":
                    guard let device = devices[account]?.first, let pair = try key(account) else { throw VEXAPIError.invalidResponse }
                    let config = "[Interface]\nPrivateKey = \(pair.privateKey)\nAddress = 192.0.2.2/32\n[Peer]\nPublicKey = fixture-peer\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n"
                    return try response(["device_id": device.id, "client_public_key": device.publicKey ?? "", "client_key_epoch": device.keyEpoch ?? 1,
                        "version": 123, "config": config, "assigned_ipv4": "192.0.2.2/32", "revoked": false, "rotation_required": false])
                default: throw VEXAPIError.invalidResponse
                }
            }
        }
        private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    }
}

private final class MemoryVpnIdentityKeychain: VEXDeviceIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for account: String, allowAuthenticationUI: Bool) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func stringIfPresent(for account: String, allowAuthenticationUI: Bool) throws -> String? { string(for: account, allowAuthenticationUI: allowAuthenticationUI) }
    func setString(_ value: String, for account: String, requiresBiometricAuthentication: Bool) throws { lock.lock(); defer { lock.unlock() }; values[account] = value }
}

private actor AccountGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if released { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { released = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
