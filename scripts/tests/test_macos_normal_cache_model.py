#!/usr/bin/env python3
"""Run actual normal cache model bodies in a D-scoped disposable filesystem.

Legacy adapters inject ONLY the filesystem root and forward owner-labelled
methods into original unowned methods. No cache policy is reimplemented.
Expected safety assertions are identical for every supplied source ROOT.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import os

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
        let device = try JSONDecoder().decode(VpnDevice.self, from: Data(#"{"id":"fixture-device","status":"active"}"#.utf8))
        var tunnel = PreparedTunnel(device:device, config:"fixture-config",locationId:"de",profileVersion:7,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture",rotationRequired:false,awgVersion:3)
        let signed = try JSONDecoder().decode(ManagedVpnProfile.self, from: Data(#"{"device_id":"fixture-device","version":7,"authorization":{"algorithm":"ECDSA_P256_SHA256_DER","key_id":"fixture-public-only","payload_base64":"c2lnbmVkLW9yaWdpbmFs","signature_base64":"cHJvb2Y"}}"#.utf8))
        let signedRecord = PreparedTunnelCacheRecord(tunnel: tunnel, normalAuthorizationProfile: signed)
        try cache.save(signedRecord, locationId: "signed", routingMode: .fullTunnel, owner: a)
        let signedRoundTrip = cache.load(locationId: "signed", routingMode: .fullTunnel, owner: a)?.normalAuthorizationProfile == signed
        let stagedRecord = PreparedTunnelCacheRecord(tunnel: tunnel)
        let stagedNil = stagedRecord.normalAuthorizationProfile == nil
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stagedRecord)) as! [String:Any]
        legacyObject.removeValue(forKey:"normalAuthorizationProfile")
        let legacyNil = try JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: JSONSerialization.data(withJSONObject:legacyObject)).normalAuthorizationProfile == nil
        tunnel.config="auto";try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel), locationId: "", routingMode: .fullTunnel, owner: a)
        tunnel.config="explicit-de";try cache.save(PreparedTunnelCacheRecord(tunnel: tunnel), locationId: "de", routingMode: .fullTunnel, owner: a)
        let emptyDistinctFromDE = cache.load(locationId: "", routingMode: .fullTunnel, owner: a)?.config == "auto" && cache.load(locationId: "de", routingMode: .fullTunnel, owner: a)?.config == "explicit-de"
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
        try cache.removeNormalProfiles(owner: a)
        let removalScoped = cache.load(locationId: "de", routingMode: .fullTunnel, owner: a) == nil && load(b)?.config == "B"
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside, withIntermediateDirectories:true)
        let sentinel = outside.appendingPathComponent("sentinel");try Data("keep".utf8).write(to:sentinel)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at:linked, withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:linked.appendingPathComponent("profiles"), withDestinationURL:outside)
        var symlinkDenied=false
        do {try VPNProfileCache(appDataURL:linked).removeNormalProfiles(owner:a)} catch {symlinkDenied=true}
        let checks: [(String, Bool)] = [
            ("legacy_optional_nil",legacyNil),
            ("symlink_ancestor_removal_denied",symlinkDenied && FileManager.default.fileExists(atPath:sentinel.path)),
            ("signed_original_roundtrip", signedRoundTrip),
            ("staged_proof_nil", stagedNil),
            ("empty_location_not_de", emptyDistinctFromDE),
            ("same_owner_cached_record", sameOwner),
            ("cross_account_denied", crossAccount),
            ("late_A_cannot_overwrite_B", lateOwner),
            ("installations_separate", installation),
            ("routing_modes_separate", modesSeparate),
            ("owner_namespace_removal_scoped", removalScoped),
            ("unowned_record_rejected", unowned),
            ("tampered_owner_rejected", tampered),
        ]
        for (name, okay) in checks { print("\(name)=\(okay)") }
        exit(checks.allSatisfy { $0.1 } ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(dir="/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-21-native/tmp", prefix='vex-cache-ownership-') as directory:
    temp = Path(directory)
    env = dict(os.environ, TMPDIR=str(temp), CLANG_MODULE_CACHE_PATH=str(temp / 'clang'), SWIFT_MODULECACHE_PATH=str(temp / 'swift'))
    (temp / 'main.swift').write_text(source + main)
    result = subprocess.run(['rtk','proxy','swiftc', '-swift-version', '5', '-parse-as-library',
                             str(ROOT/'macos-native/Sources/VEXNativeMac/Models/VEXModels.swift'),
                             str(temp / 'main.swift'), '-o', str(temp / 'probe')],
                            capture_output=True, text=True, env=env)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    result = subprocess.run(['rtk','proxy',str(temp / 'probe'), str(temp / 'cache')], env=env)
    legacy = subprocess.run(['rtk','proxy',str(temp / 'probe'), str(temp / 'cache/legacy'), '--legacy'], env=env)
    raise SystemExit(result.returncode or legacy.returncode)
