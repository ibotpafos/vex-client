import CryptoKit
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

struct VPNProfileCacheOwner: Codable, Equatable {
    let accountID: String
    let installationID: String

    init?(accountID: String?, installationID: String?) {
        guard let accountID = Self.normalized(accountID),
              let installationID = Self.normalized(installationID) else {
            return nil
        }
        self.accountID = accountID
        self.installationID = installationID
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct VPNProfileCache {
    private let fileManager: FileManager
    private let dataURL: URL

    init(fileManager: FileManager = .default, appDataURL: URL? = nil) {
        self.fileManager = fileManager
        if let appDataURL {
            self.dataURL = appDataURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.dataURL = base.appendingPathComponent("VEX Native", isDirectory: true)
        }
    }

    func load(locationId: String, routingMode: VpnRoutingMode, owner: VPNProfileCacheOwner) -> PreparedTunnelCacheRecord? {
        guard let data = try? Data(contentsOf: cacheURL(locationId: locationId, routingMode: routingMode, owner: owner)),
              let record = try? JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: data),
              record.cacheOwner == owner else {
            // Ownerless records are legacy data and deliberately fail closed.
            return nil
        }
        return record
    }

    func save(_ record: PreparedTunnelCacheRecord, locationId: String, routingMode: VpnRoutingMode, owner: VPNProfileCacheOwner) throws {
        var ownedRecord = record
        ownedRecord.cacheOwner = owner
        let url = cacheURL(locationId: locationId, routingMode: routingMode, owner: owner)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let data = try JSONEncoder().encode(ownedRecord)
        try data.write(to: url, options: [.atomic])
        try setOwnerOnlyPermissions(url)
    }

    /// Deletes only the account/install namespace used for normal signed profiles.
    func removeNormalProfiles(owner: VPNProfileCacheOwner) throws {
        let url = dataURL.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(digest(namespaceData(owner)), isDirectory: true)
        // Never follow a replaced namespace or ancestor outside this storage tree.
        // Callers block reuse before deletion and retain domain errors on failure.
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var ancestor = url.standardizedFileURL
        while ancestor.path != "/" {
            if (try? fileManager.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw CocoaError(.fileWriteNoPermission)
            }
            ancestor.deleteLastPathComponent()
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func writeHelperConfig(_ config: String) throws {
        let url = helperConfigURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? String(contentsOf: url, encoding: .utf8), current == config { return }
        try config.write(to: url, atomically: true, encoding: .utf8)
        try setOwnerOnlyPermissions(url)
    }

    func readHelperConfig() -> String? {
        let config = try? String(contentsOf: helperConfigURL(), encoding: .utf8)
        guard let config, config.contains("[Interface]"), config.contains("[Peer]") else { return nil }
        return config
    }

    private func cacheURL(locationId: String, routingMode: VpnRoutingMode, owner: VPNProfileCacheOwner) -> URL {
        dataURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(digest(namespaceData(owner)), isDirectory: true)
            .appendingPathComponent("\(digest(cacheKeyData(locationId: locationId, routingMode: routingMode))).json")
    }

    private func namespaceData(_ owner: VPNProfileCacheOwner) -> Data {
        lengthPrefixed([owner.accountID, owner.installationID])
    }

    private func cacheKeyData(locationId: String, routingMode: VpnRoutingMode) -> Data {
        lengthPrefixed([normalized(locationId), routingMode.rawValue])
    }

    private func lengthPrefixed(_ values: [String]) -> Data {
        var result = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func helperConfigURL() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".vex", isDirectory: true).appendingPathComponent("vex.conf")
    }

    private func normalized(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value
    }

    private func setOwnerOnlyPermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct PreparedTunnelCacheRecord: Codable, Equatable {
    var cacheOwner: VPNProfileCacheOwner?
    /// Original authenticated envelope; nil for legacy and staged-PSK records.
    var normalAuthorizationProfile: ManagedVpnProfile?
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

    init(tunnel: PreparedTunnel, normalAuthorizationProfile: ManagedVpnProfile? = nil) {
        self.normalAuthorizationProfile = normalAuthorizationProfile
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
            rotationRequired: false,
            awgVersion: awgVersion ?? 3
        )
    }
}
