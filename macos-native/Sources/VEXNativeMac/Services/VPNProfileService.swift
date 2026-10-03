import Foundation
import CryptoKit
import VEXHelperCore

@MainActor
struct VPNProfileService {
    private let api: VEXAPIClient
    private let identityStore: VEXDeviceIdentityStore
    private let keyStore: WireGuardKeyStore
    private let cache: VPNProfileCache
    private let profileAuthorization: NativeVPNProfileAuthorizationVerifier
    private let normalCacheReuse = NativeNormalProfileCacheReuseControl()

    init(
        api: VEXAPIClient = VEXAPIClient(),
        identityStore: VEXDeviceIdentityStore = VEXDeviceIdentityStore(),
        keyStore: WireGuardKeyStore = WireGuardKeyStore(),
        cache: VPNProfileCache = VPNProfileCache(),
        profileAuthorization: NativeVPNProfileAuthorizationVerifier = .bundled()
    ) {
        self.api = api
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.cache = cache
        self.profileAuthorization = profileAuthorization
    }

    nonisolated static let awgVersion = 3

    func resolveProfile(
        accessToken: String,
        locationId: String,
        routingMode: VpnRoutingMode,
        forceRefresh: Bool = false,
        writeHelperConfig: Bool = true,
        prevalidatedEntitlement: Entitlement? = nil,
        accountID: String? = nil,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> PreparedTunnel {
        try validateCurrent()
        guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }
        let normalizedLocationId = locationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bypassRegion = bypassRegion(for: routingMode)
        // Cache admission uses existing local files only: no Keychain migration,
        // key generation, device registration, entitlement/API call or DNS.
        if !forceRefresh,
           let installationID = identityStore.existingDeviceId(),
           let owner = VPNProfileCacheOwner(accountID: accountID, installationID: installationID),
           !normalCacheReuse.isBlocked(owner),
           let pair = keyStore.existingForStagedProfile(),
           let record = cache.load(locationId: normalizedLocationId, routingMode: routingMode, owner: owner) {
            let cacheGeneration = normalCacheReuse.generation(owner)
            if let prevalidatedEntitlement, !prevalidatedEntitlement.hasPaidAccess {
                try? invalidateNormalCache(accountID: accountID)
                throw VPNProfileError.subscriptionInactive
            }
            // A failed proof is a miss, never a timeout/route fallback. Current
            // session errors are not swallowed or converted into provisioning.
            let prepared = try? prepareVerifiedNormalCache(record, owner: owner, keyPair: pair,
                locationId: normalizedLocationId, routingMode: routingMode, bypassRegion: bypassRegion)
            try validateCurrent()
            if let prepared {
                if writeHelperConfig {
                    try await writeSanitizedHelperConfig(prepared.config, validateCurrent: {
                        try validateCurrent()
                        try normalCacheReuse.validateGeneration(cacheGeneration, owner: owner)
                    })
                }
                try validateCurrent()
                try normalCacheReuse.validateGeneration(cacheGeneration, owner: owner)
                return prepared
            }
        }
        // Never infer ownership from a bearer token: absent/blank ownership disables cache use.
        let externalDeviceId = identityStore.getOrCreateDeviceId()
        let cacheOwner = VPNProfileCacheOwner(accountID: accountID, installationID: externalDeviceId)
        guard let cacheOwner else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }
        let cacheGeneration = normalCacheReuse.generation(cacheOwner)
        // Complete responses are still required on a cache miss. Legacy caches,
        // staged-PSK records, expired or unsigned-client-bound policies are misses.

        let entitlement: Entitlement
        if let prevalidatedEntitlement {
            entitlement = prevalidatedEntitlement
        } else {
            entitlement = try await api.entitlement(accessToken: accessToken)
        }
        try validateCurrent()
        try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)
        guard entitlement.hasPaidAccess else {
            try? invalidateNormalCache(accountID: accountID)
            throw VPNProfileError.subscriptionInactive
        }

        let keyPair = try keyStore.getOrCreate()
        var device = try await activeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: keyPair.publicKey,
            keyEpoch: keyPair.keyEpoch,
            locationId: normalizedLocationId,
            validateCurrent: {
                try validateCurrent()
                try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)
            }
        )
        try validateCurrent()
        try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)
        if needsKeySync(device: device, keyPair: keyPair) {
            device = try await api.rotateManagedVpnKey(
                accessToken: accessToken,
                deviceId: device.id,
                keyPair: keyPair,
                prefix: "native-sync-key"
            )
            try validateCurrent()
            try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)
        }
        let managedProfile = try await api.managedVpnProfile(
                accessToken: accessToken,
                deviceId: device.id,
                locationId: normalizedLocationId,
                routingMode: routingMode,
                bypassRegion: bypassRegion,
                knownVersion: nil
            )
        try validateCurrent()
        try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)

        if managedProfile.revoked == true {
            try? invalidateNormalCache(accountID: accountID)
            throw VPNProfileError.deviceRevoked
        }

        return try await persistManagedProfile(
            managedProfile,
            cached: nil,
            cacheOwner: cacheOwner,
            device: device,
            keyPair: keyPair,
            locationId: normalizedLocationId,
            routingMode: routingMode,
            bypassRegion: bypassRegion,
            writeHelperConfig: writeHelperConfig,
            validateCurrent: {
                try validateCurrent()
                try normalCacheReuse.validateGeneration(cacheGeneration, owner: cacheOwner)
            }
        )
    }

    /// Removes only profile storage. Never changes helper/active tunnel/key state.
    /// Block reuse before attempting deletion: a filesystem error cannot silently
    /// preserve an eligible cache until a fresh authenticated response is saved.
    func invalidateNormalCache(accountID: String?) throws {
        guard let installationID = identityStore.existingDeviceId(),
              let owner = VPNProfileCacheOwner(accountID: accountID, installationID: installationID) else { return }
        normalCacheReuse.block(owner)
        try cache.removeNormalProfiles(owner: owner)
    }

    /// Fetches and admits a signed profile without identity, key, helper, or tunnel mutation.
    func refreshRegisteredNormalProfile(
        accessToken: String, device: VpnDevice, locationId: String, routingMode: VpnRoutingMode,
        accountID: String, validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> PreparedTunnel {
        try validateCurrent()
        let locationId = locationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bypass = bypassRegion(for: routingMode)
        guard device.status == "active", device.platform?.lowercased() == "macos",
              device.provisioningMode == "managed_native", device.clientKeyOwnership == "client",
              device.protocol?.lowercased() == "amneziawg",
              let installation = device.externalDeviceId,
              let existingInstallation = identityStore.existingDeviceId(), existingInstallation == installation,
              let owner = VPNProfileCacheOwner(accountID: accountID, installationID: installation),
              let keyPair = keyStore.existingForStagedProfile(),
              let raw = Data(base64Encoded: keyPair.privateKey), raw.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw),
              key.publicKey.rawRepresentation.base64EncodedString() == keyPair.publicKey,
              device.publicKey == keyPair.publicKey else { throw VPNProfileError.incompleteProfile("registered normal profile") }
        let cacheGeneration = normalCacheReuse.generation(owner)
        let profile = try await api.readOnlyManagedVpnProfile(accessToken: accessToken, deviceId: device.id,
            locationId: locationId, routingMode: routingMode, bypassRegion: bypass)
        try validateCurrent()
        try normalCacheReuse.validateGeneration(cacheGeneration, owner: owner)
        guard profile.revoked != true, profile.unchanged != true, profile.rotationRequired != true else {
            throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch
        }
        let verified = try profileAuthorization.verifyNormalProfile(profile, ownerAccountID: owner.accountID,
            managedDeviceID: device.id, requestedLocationID: locationId, routingMode: routingMode.rawValue,
            bypassRegion: bypass, expectedProfileVersion: profile.version ?? 0,
            expectedClientPublicKey: keyPair.publicKey, expectedClientKeyEpoch: keyPair.keyEpoch,
            expectedInstallationID: installation, requireSignedClientBinding: true,
            requireSignedBypassCounts: routingMode == .allExceptRu)
        let clean = verified.profile
        let config = try Self.buildRawManagedProfileConfig(clean, keyPair: keyPair, mtu: verified.mtu,
            persistentKeepalive: verified.persistentKeepalive, resolveEndpoint: false)
        try VEXHelperCore.AwgConfigAdmission.validate(config)
        let tunnel = PreparedTunnel(device: device.withManagedProfile(clean, locationId: verified.assignedLocationID),
            config: config, locationId: locationId, profileVersion: clean.version, routingMode: routingMode,
            bypassRegion: bypass, bypassRangesCount: verified.bypassRangesCount, bypassDomainsCount: verified.bypassDomainsCount,
            routingPolicyVersion: clean.routingPolicyVersion ?? VEXAppInfo.routingPolicyVersion,
            rotationRequired: false, awgVersion: Self.awgVersion,
            normalAuthorizationExpiresAt: verified.expiresAt)
        try validateCurrent()
        try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel, normalAuthorizationProfile: profile), locationId: locationId, routingMode: routingMode, owner: owner)
        normalCacheReuse.unblock(owner)
        try validateCurrent()
        return tunnel
    }

    /// Revalidates signed authority, not cached config/freshness flags. The signed
    /// five-minute issued-at window bounds offline stale authority; an offline
    /// client cannot attest unknown remote revocation. Push revalidation remains
    /// a separate authenticated reconciliation requirement.
    private func prepareVerifiedNormalCache(
        _ record: PreparedTunnelCacheRecord, owner: VPNProfileCacheOwner, keyPair: WireGuardKeyPair,
        locationId: String, routingMode: VpnRoutingMode, bypassRegion: String?, now: Date = Date()
    ) throws -> PreparedTunnel {
        guard record.cacheOwner == owner, record.locationId == locationId, record.routingMode == routingMode,
              record.bypassRegion == bypassRegion, record.awgVersion == Self.awgVersion,
              record.device.status == "active", record.device.externalDeviceId == owner.installationID,
              let profile = record.normalAuthorizationProfile, profile.rotationRequired != true,
              record.profileVersion == profile.version,
              let privateBytes = Data(base64Encoded: keyPair.privateKey), privateBytes.count == 32,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes),
              privateKey.publicKey.rawRepresentation.base64EncodedString() == keyPair.publicKey,
              record.device.publicKey == keyPair.publicKey else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }
        let verified = try profileAuthorization.verifyNormalProfile(profile, ownerAccountID: owner.accountID,
            managedDeviceID: record.device.id, requestedLocationID: locationId, routingMode: routingMode.rawValue,
            bypassRegion: bypassRegion, expectedProfileVersion: profile.version ?? 0,
            expectedClientPublicKey: keyPair.publicKey, expectedClientKeyEpoch: keyPair.keyEpoch,
            expectedInstallationID: owner.installationID, requireSignedClientBinding: true,
            requireSignedBypassCounts: routingMode == .allExceptRu, now: now)
        guard now.timeIntervalSince(verified.issuedAt) >= 0, now.timeIntervalSince(verified.issuedAt) <= 300 else {
            throw NativeVPNProfileAuthorizationVerifier.Failure.expired
        }
        let clean = verified.profile
        let config = try Self.buildRawManagedProfileConfig(clean, keyPair: keyPair, mtu: verified.mtu,
            persistentKeepalive: verified.persistentKeepalive, resolveEndpoint: false)
        try VEXHelperCore.AwgConfigAdmission.validate(config)
        return PreparedTunnel(device: record.device.withManagedProfile(clean, locationId: verified.assignedLocationID),
            config: config, locationId: locationId, profileVersion: clean.version, routingMode: routingMode,
            bypassRegion: bypassRegion, bypassRangesCount: verified.bypassRangesCount, bypassDomainsCount: verified.bypassDomainsCount,
            routingPolicyVersion: clean.routingPolicyVersion ?? VEXAppInfo.routingPolicyVersion,
            rotationRequired: false, awgVersion: Self.awgVersion,
            normalAuthorizationExpiresAt: verified.expiresAt)
    }

    /// Admission is read-only with respect to identity, cache and helper configuration.
    func existingStagedPSKClientPublicKey() throws -> String {
        guard let pair = keyStore.existingForStagedProfile(),
              let raw = Data(base64Encoded: pair.privateKey), raw.count == 32,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw),
              privateKey.publicKey.rawRepresentation.base64EncodedString() == pair.publicKey else {
            throw VPNProfileError.incompleteProfile("existing client key")
        }
        return pair.publicKey
    }

    /// Builds only in memory from a verified signed policy. No fetch, cache promotion,
    /// key creation/migration, DNS resolution or helper write is allowed before cutover.
    func prepareStagedPSKProfile(
        _ verified: NativeVPNProfileAuthorizationVerifier.Verified,
        basedOn previous: PreparedTunnel
    ) throws -> PreparedTunnel {
        let profile = verified.envelope.profile
        guard !verified.envelope.activate,
              profile.deviceId == previous.device.id,
              let version = profile.version, version == verified.envelope.profileVersion,
              version > (previous.profileVersion ?? 0),
              profile.clientPublicKey == (try existingStagedPSKClientPublicKey()),
              let pair = keyStore.existingForStagedProfile() else {
            throw VPNProfileError.incompleteProfile("staged profile binding")
        }
        let config = try Self.buildRawManagedProfileConfig(
            profile, keyPair: pair, mtu: verified.mtu,
            persistentKeepalive: verified.persistentKeepalive, resolveEndpoint: false
        )
        try VEXHelperCore.AwgConfigAdmission.validate(config)
        return PreparedTunnel(
            device: previous.device.withManagedProfile(profile, locationId: previous.locationId),
            config: config, locationId: previous.locationId, profileVersion: version,
            routingMode: previous.routingMode, bypassRegion: previous.bypassRegion,
            bypassRangesCount: profile.bypassRanges?.count ?? 0,
            bypassDomainsCount: profile.bypassDomains?.count ?? 0,
            routingPolicyVersion: profile.routingPolicyVersion ?? previous.routingPolicyVersion,
            rotationRequired: false, awgVersion: Self.awgVersion
        )
    }

    /// Cache promotion is a post-cutover step, scoped to the captured account/install.
    func promoteStagedPSKProfile(_ tunnel: PreparedTunnel, owner: NativePushPSKEventOwner) throws {
        guard let cacheOwner = VPNProfileCacheOwner(accountID: owner.accountID, installationID: owner.installationID) else {
            throw VPNProfileError.incompleteProfile("staged profile owner")
        }
        try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel), locationId: tunnel.locationId,
                       routingMode: tunnel.routingMode, owner: cacheOwner)
    }

    /// Retained material is not admission. Rebuild every candidate field from a
    /// freshly verified signed envelope and the EXISTING key; reuse ONLY the
    /// exact retained endpoint resolution, which the independent root digest
    /// proof must also authenticate. No DNS, API, key generation or helper write.
    func verifyProtectedRestartMaterial(_ material: NativeProtectedRestartStore.Material,
        verified: NativeVPNProfileAuthorizationVerifier.Verified, owner: NativePushPSKEventOwner) throws -> PreparedTunnel {
        let previous = material.source.tunnel
        let key = try existingStagedPSKClientPublicKey()
        guard previous.device.externalDeviceId == owner.installationID, previous.device.publicKey == key,
              previous.device.status == "active", previous.awgVersion == Self.awgVersion,
              verified.envelope.rotationID == material.rotationID else { throw NativeProtectedRestartStore.Failure.mismatch }
        let next = try prepareStagedPSKProfile(verified, basedOn: previous)
        guard next == material.candidate.tunnel,
              NativeProtectedReplacementCoordinator.digest(material.sourceConfig) == material.intent.sourceSHA256,
              NativeProtectedReplacementCoordinator.digest(material.candidateConfig) == material.intent.candidateSHA256 else {
            throw NativeProtectedRestartStore.Failure.mismatch
        }
        try AwgConfigAdmission.validate(material.sourceConfig)
        try AwgConfigAdmission.validate(material.candidateConfig)
        let lines = material.candidateConfig.split(whereSeparator: \.isNewline).filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Endpoint")
        }
        guard lines.count == 1, let separator = lines[0].firstIndex(of: "=") else { throw NativeProtectedRestartStore.Failure.mismatch }
        let endpoint = String(lines[0][lines[0].index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard let port = verified.envelope.profile.port,
              endpoint.split(separator: ":", omittingEmptySubsequences: false).last == Substring(String(port)) else {
            throw NativeProtectedRestartStore.Failure.mismatch
        }
        let rebuilt = try SystemTunnelController.sanitizedConfig(from: Self.sanitizedMacOSHelperConfig(next.config,
            endpointResolver: { _ in endpoint }))
        guard rebuilt == material.candidateConfig else { throw NativeProtectedRestartStore.Failure.mismatch }
        return next
    }

    private func persistManagedProfile(
        _ managedProfile: ManagedVpnProfile,
        cached: PreparedTunnelCacheRecord?,
        cacheOwner: VPNProfileCacheOwner?,
        device: VpnDevice,
        keyPair: WireGuardKeyPair,
        locationId normalizedLocationId: String,
        routingMode effectiveRoutingMode: VpnRoutingMode,
        bypassRegion effectiveBypassRegion: String?,
        writeHelperConfig: Bool,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> PreparedTunnel {
        try validateCurrent()
        if managedProfile.revoked == true {
            throw VPNProfileError.deviceRevoked
        }
        guard let cacheOwner else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }
        // There is no assigned-location outer JSON field. Bind the exact request
        // separately, then use the assignment authenticated by the signed policy.
        let verified = try profileAuthorization.verifyNormalProfile(
            managedProfile, ownerAccountID: cacheOwner.accountID, managedDeviceID: device.id,
            requestedLocationID: normalizedLocationId, routingMode: effectiveRoutingMode.rawValue,
            bypassRegion: effectiveBypassRegion, expectedProfileVersion: managedProfile.version ?? 0,
            expectedClientPublicKey: keyPair.publicKey, expectedClientKeyEpoch: keyPair.keyEpoch,
            expectedInstallationID: cacheOwner.installationID
        )
        guard let privateBytes = Data(base64Encoded: keyPair.privateKey), privateBytes.count == 32,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes),
              privateKey.publicKey.rawRepresentation.base64EncodedString() == keyPair.publicKey,
              managedProfile.clientPublicKey == keyPair.publicKey,
              managedProfile.clientKeyEpoch == keyPair.keyEpoch,
              device.publicKey == keyPair.publicKey else {
            throw VPNProfileError.incompleteProfile("normal client key binding")
        }
        let profile = verified.profile
        let config = try Self.buildRawManagedProfileConfig(
            profile, keyPair: keyPair, mtu: verified.mtu,
            persistentKeepalive: verified.persistentKeepalive, resolveEndpoint: false
        )
        try VEXHelperCore.AwgConfigAdmission.validate(config)
        let nextDevice = device.withManagedProfile(profile, locationId: verified.assignedLocationID)
        let tunnel = PreparedTunnel(
            device: nextDevice,
            config: config,
            locationId: normalizedLocationId,
            profileVersion: profile.version,
            routingMode: effectiveRoutingMode,
            bypassRegion: effectiveBypassRegion,
            bypassRangesCount: verified.bypassRangesCount,
            bypassDomainsCount: verified.bypassDomainsCount,
            routingPolicyVersion: profile.routingPolicyVersion ?? VEXAppInfo.routingPolicyVersion,
            rotationRequired: profile.rotationRequired == true,
            awgVersion: Self.awgVersion,
            normalAuthorizationExpiresAt: verified.expiresAt
        )
        try validateCurrent()
        try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel, normalAuthorizationProfile: managedProfile), locationId: normalizedLocationId, routingMode: effectiveRoutingMode, owner: cacheOwner)
        normalCacheReuse.unblock(cacheOwner)
        if writeHelperConfig {
            try await writeSanitizedHelperConfig(config, validateCurrent: validateCurrent)
        }
        try validateCurrent()
        return tunnel
    }

    func rotateKey(accessToken: String, currentTunnel: PreparedTunnel?, writeHelperConfig: Bool = true, accountID: String? = nil,
                   validateCurrent: @MainActor () throws -> Void = {}) async throws -> PreparedTunnel? {
        try validateCurrent()
        guard let currentTunnel else { return nil }
        let nextKey = try keyStore.rotate()
        _ = try await api.rotateManagedVpnKey(
            accessToken: accessToken,
            deviceId: currentTunnel.device.id,
            keyPair: nextKey,
            prefix: "native-rotate-key"
        )
        try validateCurrent()
        return try await resolveProfile(
            accessToken: accessToken,
            locationId: currentTunnel.locationId,
            routingMode: currentTunnel.routingMode,
            forceRefresh: true,
            writeHelperConfig: writeHelperConfig,
            accountID: accountID,
            validateCurrent: validateCurrent
        )
    }

    @discardableResult
    func writeHelperConfig(for tunnel: PreparedTunnel, validateCurrent: @MainActor () throws -> Void = {}) async throws -> String {
        try await writeSanitizedHelperConfig(tunnel.config, validateCurrent: validateCurrent)
    }

    /// Candidate preparation only; protected sources come from the confirmed
    /// memory admission, never from a second endpoint resolution here.
    func prepareProtectedHelperConfig(for tunnel: PreparedTunnel, validateCurrent: @MainActor () throws -> Void) async throws -> String {
        try validateCurrent()
        let sanitized = await Self.sanitizedHelperConfigOffMain(tunnel.config)
        try validateCurrent()
        let canonical = try SystemTunnelController.sanitizedConfig(from: sanitized)
        try AwgConfigAdmission.validate(canonical)
        return canonical
    }

    func stageProtectedHelperConfig(_ config: String, validateCurrent: @MainActor () throws -> Void) throws {
        try validateCurrent()
        try AwgConfigAdmission.validate(config)
        try cache.writeHelperConfig(config)
    }

    @discardableResult
    private func writeSanitizedHelperConfig(_ config: String, validateCurrent: @MainActor () throws -> Void = {}) async throws -> String {
        try validateCurrent()
        let sanitized = await Self.sanitizedHelperConfigOffMain(config)
        try validateCurrent()
        let canonical = try SystemTunnelController.sanitizedConfig(from: sanitized)
        try AwgConfigAdmission.validate(canonical)
        try cache.writeHelperConfig(canonical)
        return canonical
    }

    nonisolated private static func sanitizedHelperConfigOffMain(_ config: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            Self.sanitizedMacOSHelperConfig(config, endpointResolver: Self.resolveConfigEndpoint)
        }.value
    }

    private func activeDevice(
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> VpnDevice {
        let devices = try await api.vpnDevices(accessToken: accessToken)
        try validateCurrent()

        // Match in priority order: exact id, then legacy per-location id
        // ("id:location"), then any legacy physical-device prefix ("id:").
        let candidates: [(VpnDevice) -> Bool] = [
            { $0.externalDeviceId == externalDeviceId },
            { $0.externalDeviceId == "\(externalDeviceId):\(locationId)" },
            { ($0.externalDeviceId ?? "").hasPrefix("\(externalDeviceId):") },
        ]

        for matches in candidates {
            if let device = devices.first(where: { isActiveManagedDevice($0) && matches($0) }) {
                return try await syncNativeDeviceMetadataIfNeeded(
                    device,
                    accessToken: accessToken,
                    externalDeviceId: externalDeviceId,
                    publicKey: publicKey,
                    keyEpoch: keyEpoch,
                    locationId: locationId,
                    validateCurrent: validateCurrent
                )
            }
        }
        return try await registerNativeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: publicKey,
            keyEpoch: keyEpoch,
            locationId: locationId,
            validateCurrent: validateCurrent
        )
    }

    private func syncNativeDeviceMetadataIfNeeded(
        _ device: VpnDevice,
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> VpnDevice {
        try validateCurrent()
        guard nativeDeviceMetadataNeedsSync(device, externalDeviceId: externalDeviceId) else {
            return device
        }
        return try await registerNativeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: publicKey,
            keyEpoch: keyEpoch,
            locationId: locationId,
            validateCurrent: validateCurrent
        )
    }

    private func registerNativeDevice(
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async throws -> VpnDevice {
        try validateCurrent()
        let identityFields = await nativeDeviceIdentityRegistrationFields(
            accessToken: accessToken,
            installationId: externalDeviceId,
            wireGuardPublicKey: publicKey,
            validateCurrent: validateCurrent
        )
        try validateCurrent()
        return try await api.registerNativeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: publicKey,
            keyEpoch: keyEpoch,
            locationId: locationId,
            identityFields: identityFields
        )
    }

    private func nativeDeviceMetadataNeedsSync(_ device: VpnDevice, externalDeviceId: String) -> Bool {
        normalized(device.externalDeviceId) != externalDeviceId ||
            normalized(device.platform).lowercased() != "macos" ||
            normalized(device.appVersion) != VEXAppInfo.version
    }

    private func nativeDeviceIdentityRegistrationFields(
        accessToken: String,
        installationId: String,
        wireGuardPublicKey: String,
        validateCurrent: @MainActor () throws -> Void = {}
    ) async -> [String: String] {
        do {
            try validateCurrent()
            let identity = try identityStore.getOrCreateDeviceIdentity()
            let challenge = try await api.deviceIdentityChallenge(
                accessToken: accessToken,
                installationId: installationId,
                purpose: "register"
            )
            try validateCurrent()
            let publicKey = identity.publicKeyJWK
            let payload = VEXDeviceIdentity.signaturePayload(
                challenge: challenge,
                installationId: installationId,
                identityPublicKey: publicKey,
                wireGuardPublicKey: wireGuardPublicKey
            )
            return [
                "identity_public_key": publicKey,
                "identity_key_type": VEXDeviceIdentity.keyType,
                "identity_challenge_id": challenge.id,
                "identity_signature": try identity.signature(for: payload),
            ]
        } catch {
            return [:]
        }
    }

    nonisolated private static func buildRawManagedProfileConfig(
        _ profile: ManagedVpnProfile, keyPair: WireGuardKeyPair,
        mtu: Int = 1360, persistentKeepalive: Int = 25, resolveEndpoint: Bool = true
    ) throws -> String {
        guard !keyPair.privateKey.isEmpty else { throw VPNProfileError.incompleteProfile("privateKey") }
        guard let address = profile.assignedIpv4, !address.isEmpty else { throw VPNProfileError.incompleteProfile("assigned_ipv4") }
        guard let endpoint = managedProfileEndpoint(profile), !endpoint.isEmpty else { throw VPNProfileError.incompleteProfile("endpoint") }
        let configEndpoint = resolveEndpoint ? resolveConfigEndpoint(endpoint) : endpoint
        guard let serverPublicKey = profile.serverPublicKey, !serverPublicKey.isEmpty else { throw VPNProfileError.incompleteProfile("server_public_key") }

        let dns = clean(profile.dns)
        let allowedIps = clean(profile.allowedIps)
        let presharedKey = profile.presharedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let presharedLine = (presharedKey?.isEmpty == false) ? "PresharedKey = \(presharedKey!)\n" : ""
        return """
        [Interface]
        PrivateKey = \(keyPair.privateKey)
        Address = \(address)
        DNS = \((dns.isEmpty ? ["1.1.1.1", "8.8.8.8"] : dns).joined(separator: ", "))
        MTU = \(mtu)
        \(try Self.amneziaConfig(profile.amnezia))

        [Peer]
        PublicKey = \(serverPublicKey)
        \(presharedLine)Endpoint = \(configEndpoint)
        AllowedIPs = \((allowedIps.isEmpty ? ["0.0.0.0/0"] : allowedIps).joined(separator: ", "))
        PersistentKeepalive = \(persistentKeepalive)

        """
    }

    nonisolated static func amneziaConfig(_ amnezia: ManagedVpnAmnezia?) throws -> String {
        guard let amnezia else { return "" }
        var lines: [String] = []
        addNumber("Jc", amnezia.jc, to: &lines)
        addNumber("Jmin", amnezia.jmin, to: &lines)
        addNumber("Jmax", amnezia.jmax, to: &lines)
        addNumber("S1", amnezia.s1, to: &lines)
        addNumber("S2", amnezia.s2, to: &lines)
        addNumber("S3", amnezia.s3, to: &lines)
        addNumber("S4", amnezia.s4, to: &lines)
        addString("H1", amnezia.h1, to: &lines)
        addString("H2", amnezia.h2, to: &lines)
        addString("H3", amnezia.h3, to: &lines)
        addString("H4", amnezia.h4, to: &lines)
        addString("I1", amnezia.i1, to: &lines)
        addString("I2", amnezia.i2, to: &lines)
        addString("I3", amnezia.i3, to: &lines)
        addString("I4", amnezia.i4, to: &lines)
        addString("I5", amnezia.i5, to: &lines)
        addString("HeaderProtectionKey", amnezia.headerProtectionKey, to: &lines)
        addString("ContentPaddingAddition", amnezia.contentPaddingAddition, to: &lines)
        addString("RekeyAfterTime", amnezia.rekeyAfterTime, to: &lines)
        addString("RekeyTimeout", amnezia.rekeyTimeout, to: &lines)
        addString("RejectAfterTime", amnezia.rejectAfterTime, to: &lines)
        addString("KeepaliveTimeout", amnezia.keepaliveTimeout, to: &lines)
        addString("MaxHandshakeAttempts", amnezia.maxHandshakeAttempts, to: &lines)
        try NativeAwgBoolean.append("RandomTrailers", amnezia.randomTrailers, to: &lines)
        try NativeAwgBoolean.append("DisableCookies", amnezia.disableCookies, to: &lines)
        return lines.isEmpty ? "" : "\(lines.joined(separator: "\n"))\n"
    }

    nonisolated private static func managedProfileEndpoint(_ profile: ManagedVpnProfile) -> String? {
        guard let server = profile.server, !server.isEmpty else { return nil }
        guard let port = profile.port, port > 0 else { return server }
        return "\(server):\(port)"
    }

    nonisolated static func sanitizedMacOSHelperConfig(
        _ config: String,
        endpointResolver: (String) -> String = { $0 }
    ) -> String {
        let hasIPv6Address = configHasIPv6InterfaceAddress(config)
        return config
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("AllowedIPs"),
                   let separator = line.firstIndex(of: "="),
                   !hasIPv6Address {
                    return sanitizedIPv4AllowedIPsLine(line, separator: separator)
                }
                guard trimmed.hasPrefix("Endpoint"),
                      let separator = line.firstIndex(of: "=") else { return line }
                let endpoint = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !endpoint.isEmpty else { return line }
                let prefix = String(line[...separator])
                return "\(prefix) \(endpointResolver(endpoint))"
            }
            .joined(separator: "\n")
    }

    nonisolated private static func configHasIPv6InterfaceAddress(_ config: String) -> Bool {
        config.split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("Address"),
                  let separator = line.firstIndex(of: "=") else {
                return false
            }
            return line[line.index(after: separator)...]
                .split(separator: ",")
                .contains { $0.contains(":") }
        }
    }

    nonisolated private static func sanitizedIPv4AllowedIPsLine(_ line: String, separator: String.Index) -> String {
        let prefix = String(line[...separator])
        let values = line[line.index(after: separator)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(":") }
        return "\(prefix) \((values.isEmpty ? ["0.0.0.0/0"] : values).joined(separator: ", "))"
    }

    nonisolated static func cachedProfileNeedsRefresh(
        _ cached: PreparedTunnelCacheRecord,
        requestedLocationId: String,
        requestedRoutingMode: VpnRoutingMode,
        allowStale: Bool = false,
        now: Date = Date()
    ) -> Bool {
        let requestedLocationId = normalizedLocationId(requestedLocationId)
        if normalizedLocationId(cached.locationId) != requestedLocationId {
            return true
        }
        if cached.routingMode != requestedRoutingMode {
            return true
        }
        // Legacy cache entries were provisioned for AWG2; force a fresh AWG3 profile.
        if (cached.awgVersion ?? 2) != awgVersion {
            return true
        }
        if cachedDeviceNodeDoesNotMatchLocation(cached.device, requestedLocationId: requestedLocationId) {
            return true
        }
        if requestedRoutingMode == .allExceptRu && hasLegacySplitRouteAllowedIPs(cached.config) {
            return true
        }
        return !allowStale && !cached.isFresh(now: now)
    }

    nonisolated private static func cachedDeviceNodeDoesNotMatchLocation(_ device: VpnDevice, requestedLocationId: String) -> Bool {
        guard let nodeId = device.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !nodeId.isEmpty else {
            return false
        }
        return nodeId != requestedLocationId && !nodeId.hasPrefix("\(requestedLocationId)-")
    }

    nonisolated private static func normalizedLocationId(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "de" : normalized
    }

    nonisolated static func hasLegacySplitRouteAllowedIPs(_ config: String) -> Bool {
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("AllowedIPs"),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let values = line[line.index(after: separator)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if values.contains("0.0.0.0/0") {
                return false
            }
            return values.count > 2
        }
        return false
    }

    nonisolated private static func resolveConfigEndpoint(_ endpoint: String) -> String {
        guard let parsed = PreparedTunnelEndpoint(endpoint),
              let port = parsed.port,
              parsed.host.rangeOfCharacter(from: CharacterSet.letters) != nil else {
            return endpoint
        }
        guard let ip = IPv4Resolver.resolve(parsed.host) else {
            return endpoint
        }
        return "\(ip):\(port)"
    }

    private func needsKeySync(device: VpnDevice, keyPair: WireGuardKeyPair) -> Bool {
        isManagedClientOwned(device) && normalized(device.publicKey) != normalized(keyPair.publicKey)
    }

    private func isActiveManagedDevice(_ device: VpnDevice) -> Bool {
        device.status == "active" && isManagedClientOwned(device) && device.protocol == "amneziawg"
    }

    private func isManagedClientOwned(_ device: VpnDevice) -> Bool {
        device.provisioningMode == "managed_native" || device.clientKeyOwnership == "client"
    }

    private func bypassRegion(for routingMode: VpnRoutingMode) -> String? {
        routingMode == .fullTunnel ? nil : VEXAppInfo.defaultBypassRegion
    }

    private func normalizeLocationId(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "de" : normalized
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func clean(_ values: [String]?) -> [String] {
        values?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
    }

    private func isValidConfig(_ config: String) -> Bool {
        config.contains("[Interface]") && config.contains("[Peer]")
    }

    nonisolated private static func addNumber(_ key: String, _ value: Int?, to lines: inout [String]) {
        if let value, value != 0 {
            lines.append("\(key) = \(value)")
        }
    }

    nonisolated private static func addString(_ key: String, _ value: String?, to lines: inout [String]) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            lines.append("\(key) = \(normalized)")
        }
    }
}

@MainActor
final class NativeNormalProfileCacheReuseControl {
    private var blockedOwners: [VPNProfileCacheOwner] = []
    private var generations: [(owner: VPNProfileCacheOwner, value: UInt64)] = []
    func generation(_ owner: VPNProfileCacheOwner) -> UInt64 { generations.first { $0.owner == owner }?.value ?? 0 }
    func validateGeneration(_ expected: UInt64, owner: VPNProfileCacheOwner) throws {
        guard generation(owner) == expected else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }
    }
    func isBlocked(_ owner: VPNProfileCacheOwner) -> Bool { blockedOwners.contains(owner) }
    func block(_ owner: VPNProfileCacheOwner) {
        // Every invalidation, including repeated blocked-owner receipts, fences
        // prior suspended fetches. Unblock does not reset the monotonic epoch.
        if let index = generations.firstIndex(where: { $0.owner == owner }) { generations[index].value &+= 1 }
        else { generations.append((owner, 1)) }
        if !isBlocked(owner) { blockedOwners.append(owner) }
    }
    func unblock(_ owner: VPNProfileCacheOwner) { blockedOwners.removeAll { $0 == owner } }
}

enum VPNProfileError: LocalizedError {
    case subscriptionInactive
    case deviceRevoked
    case unchangedProfileWithoutCache
    case incompleteProfile(String)

    var errorDescription: String? {
        switch self {
        case .subscriptionInactive:
            return "Подписка не активна."
        case .deviceRevoked:
            return "Устройство отключено администратором."
        case .unchangedProfileWithoutCache:
            return "Профиль не изменился, но локальный кэш пуст."
        case .incompleteProfile(let field):
            return "Управляемый VPN-профиль неполный: \(field)."
        }
    }
}

private extension VpnDevice {
    func withManagedProfile(_ profile: ManagedVpnProfile, locationId: String) -> VpnDevice {
        var copy = self
        copy.assignedIpv4 = profile.assignedIpv4 ?? assignedIpv4
        copy.endpoint = managedProfileEndpoint(profile) ?? endpoint
        copy.nodeId = managedProfileNodeId(profile) ?? nodeIdForLocation(locationId)
        copy.protocol = profile.protocol ?? self.protocol
        return copy
    }

    private func managedProfileEndpoint(_ profile: ManagedVpnProfile) -> String? {
        guard let server = profile.server, !server.isEmpty else { return nil }
        guard let port = profile.port, port > 0 else { return server }
        return "\(server):\(port)"
    }

    private func managedProfileNodeId(_ profile: ManagedVpnProfile) -> String? {
        guard let server = profile.server?.trimmingCharacters(in: .whitespacesAndNewlines),
              !server.isEmpty else {
            return nil
        }
        return server.split(separator: ".").first.map(String.init)
    }

    private func nodeIdForLocation(_ locationId: String) -> String {
        "\(locationId)-1"
    }
}

extension PreparedTunnel {
    var endpoint: String? {
        device.endpoint ?? configEndpoint
    }

    var configEndpoint: String? {
        config
            .split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Endpoint") }
            .flatMap { line in
                let pieces = line.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2 else { return nil }
                return String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    var lastSuccessfulEndpoint: String? {
        LastTunnelEndpointStore().endpoint(for: locationId)
    }

    func withEndpoint(_ endpoint: String) -> PreparedTunnel? {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, config.range(of: #"(?m)^Endpoint\s*="#, options: .regularExpression) != nil else { return nil }
        var copy = self
        copy.config = config.replacingOccurrences(
            of: #"(?m)^Endpoint\s*=\s*.+$"#,
            with: "Endpoint = \(normalized)",
            options: .regularExpression
        )
        copy.device.endpoint = normalized
        return copy
    }

    func withEndpointPort(_ port: UInt16) -> PreparedTunnel? {
        guard let endpoint, let parsed = PreparedTunnelEndpoint(endpoint) else { return nil }
        guard parsed.port != port else { return nil }
        return withEndpoint(parsed.formatted(port: port))
    }
}

private struct PreparedTunnelEndpoint {
    var host: String
    var port: UInt16?

    init?(_ endpoint: String) {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let suffix = value[value.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            port = UInt16(suffix)
            return
        }
        if value.filter({ $0 == ":" }).count == 1, let separator = value.lastIndex(of: ":") {
            host = String(value[..<separator])
            port = UInt16(value[value.index(after: separator)...])
            return
        }
        host = value
        port = nil
    }

    func formatted(port: UInt16) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// IPv4 resolver with a small TTL cache and a hard resolution timeout.
///
/// Endpoint resolution feeds the PF anti-leak rules and the helper config, so a
/// hanging DNS server must never stall the connect flow: after
/// `maxResolutionSeconds` the caller falls back to the hostname endpoint and
/// amneziawg-go performs its own resolution at tunnel bring-up.
enum IPv4Resolver {
    private struct Entry {
        let address: String
        let expiresAt: Date
    }

    static let maxResolutionSeconds: TimeInterval = 3
    static let cacheTTLSeconds: TimeInterval = 300

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func cachedAddress(for host: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[host] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: host)
            return nil
        }
        return entry.address
    }

    static func store(_ address: String, for host: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[host] = Entry(address: address, expiresAt: now.addingTimeInterval(cacheTTLSeconds))
    }

    static func resolve(_ host: String) -> String? {
        if let cached = cachedAddress(for: host) {
            return cached
        }
        guard let resolved = resolveWithTimeout(host) else {
            return nil
        }
        store(resolved, for: host)
        return resolved
    }

    private static func resolveWithTimeout(_ host: String) -> String? {
        let box = ResolutionBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.value = blockingResolve(host)
            semaphore.signal()
        }
        // The writer stores the value before signaling, so a successful wait
        // guarantees visibility. On timeout the blocked thread is abandoned.
        guard semaphore.wait(timeout: .now() + maxResolutionSeconds) == .success else {
            return nil
        }
        return box.value
    }

    private static func blockingResolve(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            if current.pointee.ai_family == AF_INET,
               let address = current.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                var addr = address.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buffer)
                }
            }
            cursor = current.pointee.ai_next
        }
        return nil
    }
}

private final class ResolutionBox: @unchecked Sendable {
    var value: String?
}
