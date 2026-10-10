import Foundation

enum VPNProfileCacheIdentity {
    static func canReuse(
        _ cached: PreparedTunnelCacheRecord,
        accountUserId: String,
        installationId: String,
        keyPair: WireGuardKeyPair,
        locationId: String,
        routingMode: VpnRoutingMode,
        currentDevice: VpnDevice? = nil
    ) -> Bool {
        guard !accountUserId.isEmpty,
              cached.accountUserId == accountUserId,
              cached.device.userId == nil || cached.device.userId == accountUserId,
              !cached.device.id.isEmpty,
              cached.device.status == "active",
              cached.device.publicKey == keyPair.publicKey,
              !keyPair.publicKey.isEmpty,
              let epoch = cached.device.keyEpoch, epoch > 0,
              cached.localKeyEpoch == keyPair.keyEpoch,
              cached.rotationRequired != true,
              cached.locationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == locationId.lowercased(),
              cached.routingMode == routingMode,
              cached.awgVersion == VPNProfileService.awgVersion,
              (cached.profileVersion ?? 0) > 0,
              physicalInstallation(cached.device.externalDeviceId) == installationId,
              configMatches(cached.config, keyPair: keyPair, device: cached.device) else { return false }
        if let currentDevice {
            return currentDevice.id == cached.device.id
                && currentDevice.status == "active"
                && (currentDevice.userId == nil || currentDevice.userId == accountUserId)
                && currentDevice.publicKey == cached.device.publicKey
                && currentDevice.keyEpoch == epoch
                && ipv4Address(currentDevice.assignedIpv4) == ipv4Address(cached.device.assignedIpv4)
                && physicalInstallation(currentDevice.externalDeviceId) == installationId
        }
        return true
    }

    static func confirmsUnchanged(
        _ profile: ManagedVpnProfile,
        cached: PreparedTunnelCacheRecord,
        device: VpnDevice,
        keyPair: WireGuardKeyPair
    ) -> Bool {
        profile.unchanged == true && profile.revoked != true && profile.rotationRequired != true
            && profile.version == cached.profileVersion
            && profile.deviceId == device.id
            && profile.clientPublicKey == keyPair.publicKey
            && profile.clientPublicKey == device.publicKey
            && profile.clientKeyEpoch != nil
            && profile.clientKeyEpoch == device.keyEpoch
    }

    static func configMatches(_ config: String, keyPair: WireGuardKeyPair, device: VpnDevice) -> Bool {
        guard let fields = interfaceFields(config),
              fields["privatekey"] == keyPair.privateKey,
              !keyPair.privateKey.isEmpty,
              let expected = device.assignedIpv4, !expected.isEmpty,
              let address = fields["address"] else { return false }
        let expectedIP = expected.split(separator: "/", maxSplits: 1).first.map(String.init)
        return address.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/", maxSplits: 1).first.map(String.init) == expectedIP
        }
    }

    private static func interfaceFields(_ config: String) -> [String: String]? {
        var section = ""
        var fields: [String: String] = [:]
        var peers = 0
        var interfaces = 0
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[interface]" {
                    guard interfaces == 0, peers == 0 else { return nil }
                    interfaces += 1
                } else if section == "[peer]" {
                    guard interfaces == 1, peers == 0 else { return nil }
                    peers += 1
                } else { return nil }
                continue
            }
            guard section == "[interface]", let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard fields[name] == nil else { return nil }
            fields[name] = value
        }
        return interfaces == 1 && peers == 1 ? fields : nil
    }

    private static func physicalInstallation(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    private static func ipv4Address(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", maxSplits: 1).first.map(String.init)
    }
}
