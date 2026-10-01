#!/usr/bin/env python3
"""Run actual Swift cache/record bodies in a disposable filesystem.

Legacy adapters inject ONLY the filesystem root and forward owner-labelled
methods into original unowned methods. No cache policy is reimplemented.
Expected safety assertions are identical for every supplied source ROOT.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
source = (ROOT / 'macos-native/Sources/VEXNativeMac/Services/VPNProfileCache.swift').read_text()

def function(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

if 'struct VPNProfileCacheOwner:' not in source:
    original_locator = function(source, '    private func appDataURL() -> URL')
    source = source.replace(original_locator, '''    private func appDataURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }''', 1)
    source = source.replace('struct VPNProfileCache {', '''struct VPNProfileCache {
    init(appDataURL: URL) {}
    func load(locationId: String, routingMode: VpnRoutingMode, owner: VPNProfileCacheOwner) -> PreparedTunnelCacheRecord? {
        load(locationId: locationId, routingMode: routingMode)
    }
    func save(_ record: PreparedTunnelCacheRecord, locationId: String, routingMode: VpnRoutingMode, owner: VPNProfileCacheOwner) throws {
        try save(record, locationId: locationId, routingMode: routingMode)
    }
''', 1)
    source += '''
struct VPNProfileCacheOwner {
    let accountID: String
    let installationID: String
    init?(accountID: String?, installationID: String?) {
        guard let accountID, let installationID else { return nil }
        self.accountID = accountID; self.installationID = installationID
    }
}
'''

models = (ROOT / 'macos-native/Sources/VEXNativeMac/Models/VEXModels.swift').read_text()
routing_mode = function(models, 'enum VpnRoutingMode:')
dependencies = 'import Foundation\n' + routing_mode + '''
struct VpnDevice: Codable, Equatable { var id: String = "fixture-device" }
struct PreparedTunnel {
    var device = VpnDevice()
    var config = "fixture-config"
    var locationId = "de"
    var profileVersion: Int? = 7
    var routingMode: VpnRoutingMode = .fullTunnel
    var bypassRegion: String? = nil
    var bypassRangesCount = 0
    var bypassDomainsCount = 0
    var routingPolicyVersion = "fixture-policy"
    var rotationRequired = false
    var awgVersion = 3
}
'''
main = r'''
@main struct Main {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cache = VPNProfileCache(appDataURL: root)
        let a = VPNProfileCacheOwner(accountID: "A", installationID: "install")!
        if CommandLine.arguments.count > 2 {
            let rejected = cache.load(locationId: "de", routingMode: .fullTunnel, owner: a) == nil
            print("legacy_flat_record_rejected=\(rejected)")
            exit(rejected ? 0 : 1)
        }
        let b = VPNProfileCacheOwner(accountID: "B", installationID: "install")!
        let otherInstall = VPNProfileCacheOwner(accountID: "B", installationID: "other-install")!
        var tunnel = PreparedTunnel()
        func save(_ value: String, _ owner: VPNProfileCacheOwner) throws {
            tunnel.config = value
            try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel), locationId: "de", routingMode: .fullTunnel, owner: owner)
        }
        func load(_ owner: VPNProfileCacheOwner) -> PreparedTunnelCacheRecord? {
            cache.load(locationId: "de", routingMode: .fullTunnel, owner: owner)
        }
        func files() throws -> [URL] {
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            return e.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        }
        try save("A", a)
        let sameOwner = load(a)?.config == "A"
        let crossAccount = load(b) == nil
        try save("B", b)
        try save("late-A", a)
        let lateOwner = load(b)?.config == "B"
        let installation = load(otherInstall) == nil
        let modesSeparate = cache.load(locationId: "de", routingMode: .allExceptRu, owner: a) == nil
        let aFile = try files().first { url in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            return object["config"] as? String == "late-A"
        }!
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: aFile)) as! [String: Any]
        object.removeValue(forKey: "cacheOwner")
        try JSONSerialization.data(withJSONObject: object).write(to: aFile)
        let unowned = load(a) == nil
        object["cacheOwner"] = ["accountID": "B", "installationID": "install"]
        try JSONSerialization.data(withJSONObject: object).write(to: aFile)
        let tampered = load(a) == nil
        object.removeValue(forKey: "cacheOwner")
        let flatProfiles = root.appendingPathComponent("legacy/profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: flatProfiles, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: flatProfiles.appendingPathComponent("de-\(VpnRoutingMode.fullTunnel.rawValue).json"))
        let checks: [(String, Bool)] = [
            ("same_owner_cached_record", sameOwner),
            ("cross_account_denied", crossAccount),
            ("late_A_cannot_overwrite_B", lateOwner),
            ("installations_separate", installation),
            ("routing_modes_separate", modesSeparate),
            ("unowned_record_rejected", unowned),
            ("tampered_owner_rejected", tampered),
        ]
        for (name, okay) in checks { print("\(name)=\(okay)") }
        exit(checks.allSatisfy { $0.1 } ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vex-cache-ownership-') as directory:
    temp = Path(directory)
    (temp / 'main.swift').write_text(dependencies + source + main)
    result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                             str(temp / 'main.swift'), '-o', str(temp / 'probe')],
                            capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    result = subprocess.run([str(temp / 'probe'), str(temp / 'cache')])
    legacy = subprocess.run([str(temp / 'probe'), str(temp / 'cache/legacy'), '--legacy'])
    raise SystemExit(result.returncode or legacy.returncode)
