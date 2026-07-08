import Foundation

struct VPNProfileService {
    private let api: VEXAPIClient
    private let identityStore: VEXDeviceIdentityStore
    private let keyStore: WireGuardKeyStore
    private let cache: VPNProfileCache

    init(
        api: VEXAPIClient = VEXAPIClient(),
        identityStore: VEXDeviceIdentityStore = VEXDeviceIdentityStore(),
        keyStore: WireGuardKeyStore = WireGuardKeyStore(),
        cache: VPNProfileCache = VPNProfileCache()
    ) {
        self.api = api
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.cache = cache
    }

    func resolveProfile(
        accessToken: String,
        locationId: String,
        routingMode: VpnRoutingMode,
        forceRefresh: Bool = false,
        writeHelperConfig: Bool = true
    ) async throws -> PreparedTunnel {
        let normalizedLocationId = normalizeLocationId(locationId)
        let bypassRegion = bypassRegion(for: routingMode)
        let cached = cache.load(locationId: normalizedLocationId, routingMode: routingMode)

        if !forceRefresh,
           let cached,
           !Self.cachedProfileNeedsRefresh(
                cached,
                requestedLocationId: normalizedLocationId,
                requestedRoutingMode: routingMode
           ) {
            if writeHelperConfig {
                try cache.writeHelperConfig(helperConfig(cached.config))
            }
            return cached.tunnel
        }

        let entitlement = try await api.entitlement(accessToken: accessToken)
        guard entitlement.hasPaidAccess else {
            throw VPNProfileError.subscriptionInactive
        }

        let keyPair = try keyStore.getOrCreate()
        let externalDeviceId = identityStore.getOrCreateDeviceId()
        var device = try await activeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: keyPair.publicKey,
            keyEpoch: keyPair.keyEpoch,
            locationId: normalizedLocationId
        )

        if needsKeySync(device: device, keyPair: keyPair) {
            device = try await api.rotateManagedVpnKey(
                accessToken: accessToken,
                deviceId: device.id,
                keyPair: keyPair,
                prefix: "native-sync-key"
            )
        }

        var effectiveRoutingMode = routingMode
        var effectiveBypassRegion = bypassRegion
        let managedProfile: ManagedVpnProfile
        do {
            managedProfile = try await api.managedVpnProfile(
                accessToken: accessToken,
                deviceId: device.id,
                locationId: normalizedLocationId,
                routingMode: routingMode,
                bypassRegion: bypassRegion,
                knownVersion: cached?.profileVersion
            )
        } catch {
            if error.isTimeout,
               !forceRefresh,
               let cached,
               !Self.cachedProfileNeedsRefresh(
                    cached,
                    requestedLocationId: normalizedLocationId,
                    requestedRoutingMode: routingMode,
                    allowStale: true
               ) {
                if writeHelperConfig {
                    try cache.writeHelperConfig(helperConfig(cached.config))
                }
                return cached.tunnel
            }
            if routingMode == .fullTunnel, error.isProfileProvisioningUnavailable {
                effectiveRoutingMode = .allExceptRu
                effectiveBypassRegion = VEXAppInfo.defaultBypassRegion
                managedProfile = try await api.managedVpnProfile(
                    accessToken: accessToken,
                    deviceId: device.id,
                    locationId: normalizedLocationId,
                    routingMode: .allExceptRu,
                    bypassRegion: effectiveBypassRegion,
                    knownVersion: nil
                )
                return try persistManagedProfile(
                    managedProfile,
                    cached: cached,
                    device: device,
                    keyPair: keyPair,
                    locationId: normalizedLocationId,
                    routingMode: effectiveRoutingMode,
                    bypassRegion: effectiveBypassRegion,
                    writeHelperConfig: writeHelperConfig
                )
            }
            guard routingMode != .fullTunnel, error.isTimeout else {
                throw error
            }
            effectiveRoutingMode = .fullTunnel
            effectiveBypassRegion = nil
            if !forceRefresh,
               let fallbackCached = cache.load(locationId: normalizedLocationId, routingMode: .fullTunnel),
               !Self.cachedProfileNeedsRefresh(
                    fallbackCached,
                    requestedLocationId: normalizedLocationId,
                    requestedRoutingMode: .fullTunnel
               ) {
                if writeHelperConfig {
                    try cache.writeHelperConfig(helperConfig(fallbackCached.config))
                }
                return fallbackCached.tunnel
            }
            managedProfile = try await api.managedVpnProfile(
                accessToken: accessToken,
                deviceId: device.id,
                locationId: normalizedLocationId,
                routingMode: .fullTunnel,
                bypassRegion: nil,
                knownVersion: nil
            )
        }

        if managedProfile.revoked == true {
            throw VPNProfileError.deviceRevoked
        }

        return try persistManagedProfile(
            managedProfile,
            cached: cached,
            device: device,
            keyPair: keyPair,
            locationId: normalizedLocationId,
            routingMode: effectiveRoutingMode,
            bypassRegion: effectiveBypassRegion,
            writeHelperConfig: writeHelperConfig
        )
    }

    private func persistManagedProfile(
        _ managedProfile: ManagedVpnProfile,
        cached: PreparedTunnelCacheRecord?,
        device: VpnDevice,
        keyPair: WireGuardKeyPair,
        locationId normalizedLocationId: String,
        routingMode effectiveRoutingMode: VpnRoutingMode,
        bypassRegion effectiveBypassRegion: String?,
        writeHelperConfig: Bool
    ) throws -> PreparedTunnel {
        if managedProfile.revoked == true {
            throw VPNProfileError.deviceRevoked
        }

        let config: String
        if managedProfile.unchanged == true {
            guard let cachedConfig = cached?.config, isValidConfig(cachedConfig) else {
                throw VPNProfileError.unchangedProfileWithoutCache
            }
            config = cachedConfig
        } else if let apiConfig = managedProfile.config, isValidConfig(apiConfig) {
            config = apiConfig
        } else {
            config = try managedProfileConfig(managedProfile, keyPair: keyPair)
        }

        let nextDevice = device.withManagedProfile(managedProfile, locationId: normalizedLocationId)
        let tunnel = PreparedTunnel(
            device: nextDevice,
            config: config,
            locationId: normalizedLocationId,
            profileVersion: managedProfile.version ?? cached?.profileVersion,
            routingMode: effectiveRoutingMode,
            bypassRegion: effectiveBypassRegion,
            bypassRangesCount: managedProfile.bypassRanges?.filter { !$0.isEmpty }.count ?? 0,
            bypassDomainsCount: managedProfile.bypassDomains?.filter { !$0.isEmpty }.count ?? 0,
            routingPolicyVersion: managedProfile.routingPolicyVersion ?? VEXAppInfo.routingPolicyVersion,
            rotationRequired: managedProfile.rotationRequired == true
        )
        try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel), locationId: normalizedLocationId, routingMode: effectiveRoutingMode)
        if writeHelperConfig {
            try cache.writeHelperConfig(helperConfig(config))
        }
        return tunnel
    }

    func rotateKey(accessToken: String, currentTunnel: PreparedTunnel?) async throws -> PreparedTunnel? {
        guard let currentTunnel else { return nil }
        let nextKey = try keyStore.rotate()
        _ = try await api.rotateManagedVpnKey(
            accessToken: accessToken,
            deviceId: currentTunnel.device.id,
            keyPair: nextKey,
            prefix: "native-rotate-key"
        )
        return try await resolveProfile(
            accessToken: accessToken,
            locationId: currentTunnel.locationId,
            routingMode: currentTunnel.routingMode,
            forceRefresh: true
        )
    }

    func writeHelperConfig(for tunnel: PreparedTunnel) throws {
        try cache.writeHelperConfig(helperConfig(tunnel.config))
    }

    private func activeDevice(
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String
    ) async throws -> VpnDevice {
        let devices = try await api.vpnDevices(accessToken: accessToken)
        if let exact = devices.first(where: { isActiveManagedDevice($0) && $0.externalDeviceId == externalDeviceId }) {
            return try await syncNativeDeviceMetadataIfNeeded(
                exact,
                accessToken: accessToken,
                externalDeviceId: externalDeviceId,
                publicKey: publicKey,
                keyEpoch: keyEpoch,
                locationId: locationId
            )
        }
        if let legacyLocation = devices.first(where: { isActiveManagedDevice($0) && $0.externalDeviceId == "\(externalDeviceId):\(locationId)" }) {
            return try await syncNativeDeviceMetadataIfNeeded(
                legacyLocation,
                accessToken: accessToken,
                externalDeviceId: externalDeviceId,
                publicKey: publicKey,
                keyEpoch: keyEpoch,
                locationId: locationId
            )
        }
        if let legacyPhysical = devices.first(where: {
            isActiveManagedDevice($0) && ($0.externalDeviceId ?? "").hasPrefix("\(externalDeviceId):")
        }) {
            return try await syncNativeDeviceMetadataIfNeeded(
                legacyPhysical,
                accessToken: accessToken,
                externalDeviceId: externalDeviceId,
                publicKey: publicKey,
                keyEpoch: keyEpoch,
                locationId: locationId
            )
        }
        return try await registerNativeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: publicKey,
            keyEpoch: keyEpoch,
            locationId: locationId
        )
    }

    private func syncNativeDeviceMetadataIfNeeded(
        _ device: VpnDevice,
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String
    ) async throws -> VpnDevice {
        guard nativeDeviceMetadataNeedsSync(device, externalDeviceId: externalDeviceId) else {
            return device
        }
        return try await registerNativeDevice(
            accessToken: accessToken,
            externalDeviceId: externalDeviceId,
            publicKey: publicKey,
            keyEpoch: keyEpoch,
            locationId: locationId
        )
    }

    private func registerNativeDevice(
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String
    ) async throws -> VpnDevice {
        let identityFields = await nativeDeviceIdentityRegistrationFields(
            accessToken: accessToken,
            installationId: externalDeviceId,
            wireGuardPublicKey: publicKey
        )
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
        wireGuardPublicKey: String
    ) async -> [String: String] {
        do {
            let identity = try identityStore.getOrCreateDeviceIdentity()
            let challenge = try await api.deviceIdentityChallenge(
                accessToken: accessToken,
                installationId: installationId,
                purpose: "register"
            )
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

    private func managedProfileConfig(_ profile: ManagedVpnProfile, keyPair: WireGuardKeyPair) throws -> String {
        guard !keyPair.privateKey.isEmpty else { throw VPNProfileError.incompleteProfile("privateKey") }
        guard let address = profile.assignedIpv4, !address.isEmpty else { throw VPNProfileError.incompleteProfile("assigned_ipv4") }
        guard let endpoint = managedProfileEndpoint(profile), !endpoint.isEmpty else { throw VPNProfileError.incompleteProfile("endpoint") }
        let configEndpoint = resolvedConfigEndpoint(endpoint)
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
        MTU = 1360
        \(amneziaConfig(profile.amnezia))

        [Peer]
        PublicKey = \(serverPublicKey)
        \(presharedLine)Endpoint = \(configEndpoint)
        AllowedIPs = \((allowedIps.isEmpty ? ["0.0.0.0/0"] : allowedIps).joined(separator: ", "))
        PersistentKeepalive = 25

        """
    }

    private func amneziaConfig(_ amnezia: ManagedVpnAmnezia?) -> String {
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
        return lines.isEmpty ? "" : "\(lines.joined(separator: "\n"))\n"
    }

    private func managedProfileEndpoint(_ profile: ManagedVpnProfile) -> String? {
        guard let server = profile.server, !server.isEmpty else { return nil }
        guard let port = profile.port, port > 0 else { return server }
        return "\(server):\(port)"
    }

    private func helperConfig(_ config: String) -> String {
        Self.sanitizedMacOSHelperConfig(config, endpointResolver: resolvedConfigEndpoint)
    }

    static func sanitizedMacOSHelperConfig(
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

    private static func configHasIPv6InterfaceAddress(_ config: String) -> Bool {
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

    private static func sanitizedIPv4AllowedIPsLine(_ line: String, separator: String.Index) -> String {
        let prefix = String(line[...separator])
        let values = line[line.index(after: separator)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(":") }
        return "\(prefix) \((values.isEmpty ? ["0.0.0.0/0"] : values).joined(separator: ", "))"
    }

    static func cachedProfileNeedsRefresh(
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
        if cachedDeviceNodeDoesNotMatchLocation(cached.device, requestedLocationId: requestedLocationId) {
            return true
        }
        if requestedRoutingMode == .allExceptRu && hasLegacySplitRouteAllowedIPs(cached.config) {
            return true
        }
        return !allowStale && !cached.isFresh(now: now)
    }

    private static func cachedDeviceNodeDoesNotMatchLocation(_ device: VpnDevice, requestedLocationId: String) -> Bool {
        guard let nodeId = device.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !nodeId.isEmpty else {
            return false
        }
        return nodeId != requestedLocationId && !nodeId.hasPrefix("\(requestedLocationId)-")
    }

    private static func normalizedLocationId(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "de" : normalized
    }

    static func hasLegacySplitRouteAllowedIPs(_ config: String) -> Bool {
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

    private func resolvedConfigEndpoint(_ endpoint: String) -> String {
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

    private func clean(_ values: [String]?) -> [String] {
        values?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
    }

    private func isValidConfig(_ config: String) -> Bool {
        config.contains("[Interface]") && config.contains("[Peer]")
    }

    private func addNumber(_ key: String, _ value: Int?, to lines: inout [String]) {
        if let value, value != 0 {
            lines.append("\(key) = \(value)")
        }
    }

    private func addString(_ key: String, _ value: String?, to lines: inout [String]) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            lines.append("\(key) = \(normalized)")
        }
    }
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
        nil
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

private enum IPv4Resolver {
    static func resolve(_ host: String) -> String? {
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
