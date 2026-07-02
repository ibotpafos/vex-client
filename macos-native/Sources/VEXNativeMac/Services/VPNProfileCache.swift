import Foundation

struct VPNProfileCache {
    private let fileManager = FileManager.default

    func load(locationId: String, routingMode: VpnRoutingMode) -> PreparedTunnelCacheRecord? {
        guard let data = try? Data(contentsOf: cacheURL(locationId: locationId, routingMode: routingMode)) else {
            return nil
        }
        return try? JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: data)
    }

    func save(_ record: PreparedTunnelCacheRecord, locationId: String, routingMode: VpnRoutingMode) throws {
        let url = cacheURL(locationId: locationId, routingMode: routingMode)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: [.atomic])
        try setOwnerOnlyPermissions(url)
    }

    func writeHelperConfig(_ config: String) throws {
        let url = helperConfigURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    private func cacheURL(locationId: String, routingMode: VpnRoutingMode) -> URL {
        appDataURL()
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("\(normalized(locationId))-\(routingMode.rawValue).json")
    }

    private func helperConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vex", isDirectory: true)
            .appendingPathComponent("vex.conf")
    }

    private func appDataURL() -> URL {
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
    var device: VpnDevice
    var config: String
    var locationId: String
    var profileVersion: Int?
    var routingMode: VpnRoutingMode
    var bypassRegion: String?
    var bypassRangesCount: Int
    var bypassDomainsCount: Int
    var routingPolicyVersion: String

    init(tunnel: PreparedTunnel) {
        device = tunnel.device
        config = tunnel.config
        locationId = tunnel.locationId
        profileVersion = tunnel.profileVersion
        routingMode = tunnel.routingMode
        bypassRegion = tunnel.bypassRegion
        bypassRangesCount = tunnel.bypassRangesCount
        bypassDomainsCount = tunnel.bypassDomainsCount
        routingPolicyVersion = tunnel.routingPolicyVersion
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
            rotationRequired: false
        )
    }
}
