import Foundation

/// Remembers the endpoint that last completed a successful handshake per
/// location, so reconnect attempts start from a known-good address instead of
/// replaying the default one and waiting out full handshake timeouts.
struct LastTunnelEndpointStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func endpoint(for locationId: String) -> String? {
        guard !locationId.isEmpty else { return nil }
        return defaults.string(forKey: Self.key(for: locationId))
    }

    func save(_ endpoint: String, locationId: String) {
        let trimmedLocation = locationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocation.isEmpty, !trimmedEndpoint.isEmpty else { return }
        defaults.set(trimmedEndpoint, forKey: Self.key(for: trimmedLocation))
    }

    private static func key(for locationId: String) -> String {
        "native.lastSuccessfulEndpoint.\(locationId.lowercased())"
    }
}

struct VPNProfileCache {
    private let fileManager = FileManager.default
    private let directoryURL: URL?
    private let helperConfigOverrideURL: URL?

    init(directoryURL: URL? = nil, helperConfigURL: URL? = nil) {
        self.directoryURL = directoryURL
        self.helperConfigOverrideURL = helperConfigURL
    }

    func load(locationId: String, routingMode: VpnRoutingMode, accountUserId: String? = nil) -> PreparedTunnelCacheRecord? {
        if let accountUserId,
           let record = loadRecord(at: cacheURL(locationId: locationId, routingMode: routingMode, accountUserId: accountUserId)) {
            return record
        }
        // Keep legacy records as migration hints. The service must qualify their
        // account, device and local key before using their configuration/version.
        return loadRecord(at: cacheURL(locationId: locationId, routingMode: routingMode))
    }

    private func loadRecord(at url: URL) -> PreparedTunnelCacheRecord? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: data)
    }

    func save(_ record: PreparedTunnelCacheRecord, locationId: String, routingMode: VpnRoutingMode) throws {
        let url = cacheURL(locationId: locationId, routingMode: routingMode, accountUserId: record.accountUserId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: [.atomic])
        try setOwnerOnlyPermissions(url)
    }

    func writeHelperConfig(_ config: String) throws {
        let url = helperConfigURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rewrites are skipped when the sanitized config is unchanged, so repeated
        // connect attempts do not touch disk (and trigger file-provider syncs) needlessly.
        if let current = try? String(contentsOf: url, encoding: .utf8), current == config {
            return
        }
        try config.write(to: url, atomically: true, encoding: .utf8)
        try setOwnerOnlyPermissions(url)
    }

    func readHelperConfig() -> String? {
        let config = try? String(contentsOf: helperConfigURL(), encoding: .utf8)
        guard let config,
              config.contains("[Interface]"),
              config.contains("[Peer]") else {
            return nil
        }
        return config
    }

    private func cacheURL(locationId: String, routingMode: VpnRoutingMode, accountUserId: String? = nil) -> URL {
        var directory = appDataURL().appendingPathComponent("profiles", isDirectory: true)
        if let accountUserId {
            // Encode raw UTF8 bytes without case folding or Unicode normalization.
            // Lowercase hex stays injective on case-insensitive macOS volumes;
            // base64url names can collide there ("_-" -> Xy0, "ō" -> xY0).
            let namespace = accountUserId.utf8.map { String(format: "%02x", $0) }.joined()
            directory.appendPathComponent("account-\(namespace)", isDirectory: true)
        }
        return directory.appendingPathComponent("\(normalized(locationId))-\(routingMode.rawValue).json")
    }

    private func helperConfigURL() -> URL {
        helperConfigOverrideURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vex", isDirectory: true)
            .appendingPathComponent("vex.conf")
    }

    private func appDataURL() -> URL {
        if let directoryURL { return directoryURL }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("VEX Native", isDirectory: true)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty ? "de" : value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func setOwnerOnlyPermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct PreparedTunnelCacheRecord: Codable, Equatable {
    var accountUserId: String?
    var localKeyEpoch: Int?
    var rotationRequired: Bool?
    var device: VpnDevice
    var config: String
    var locationId: String
    var profileVersion: Int?
    var routingMode: VpnRoutingMode
    var bypassRegion: String?
    var bypassRangesCount: Int
    var bypassDomainsCount: Int
    var routingPolicyVersion: String
    var fetchedAt: Date?
    var awgVersion: Int?

    init(tunnel: PreparedTunnel, accountUserId: String? = nil, localKeyEpoch: Int? = nil) {
        self.accountUserId = accountUserId
        self.localKeyEpoch = localKeyEpoch
        rotationRequired = tunnel.rotationRequired
        device = tunnel.device
        config = tunnel.config
        locationId = tunnel.locationId
        profileVersion = tunnel.profileVersion
        routingMode = tunnel.routingMode
        bypassRegion = tunnel.bypassRegion
        bypassRangesCount = tunnel.bypassRangesCount
        bypassDomainsCount = tunnel.bypassDomainsCount
        routingPolicyVersion = tunnel.routingPolicyVersion
        fetchedAt = Date()
        awgVersion = tunnel.awgVersion
    }

    var isFresh: Bool {
        isFresh(now: Date())
    }

    func isFresh(now: Date, maxAge: TimeInterval = 5 * 60) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) <= maxAge
    }

    var tunnel: PreparedTunnel {
        PreparedTunnel(
            device: device,
            config: config,
            locationId: locationId,
            profileVersion: profileVersion,
            routingMode: routingMode,
            bypassRegion: bypassRegion,
            bypassRangesCount: bypassRangesCount,
            bypassDomainsCount: bypassDomainsCount,
            routingPolicyVersion: routingPolicyVersion,
            rotationRequired: rotationRequired ?? false,
            awgVersion: awgVersion ?? 3
        )
    }
}
