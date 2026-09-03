import Foundation

final class Files: HelperFileSystem, @unchecked Sendable {
    var texts: [String: String] = [:]
    var mutations = 0
    var unreadable: String?
    func createDirectory(at path: String) throws { mutations += 1 }
    func fileExists(at path: String) -> Bool { texts[path] != nil }
    func fileSize(at path: String) -> UInt64? { nil }
    func modificationDate(at path: String) -> Date? { nil }
    func readText(at path: String) throws -> String {
        guard path != unreadable, let text = texts[path] else { throw HelperError.readFailed("fixture missing") }
        return text
    }
    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws { mutations += 1; texts[path] = text }
    func removeItem(at path: String) throws { mutations += 1; texts[path] = nil }
}
final class Commands: CommandRunning, @unchecked Sendable {
    var calls = 0
    func run(_ spec: CommandSpec) throws -> CommandResult { calls += 1; throw HelperError.commandFailed("unexpected command") }
}
final class Firewall: PFFirewallControlling, @unchecked Sendable {
    var calls = 0
    func antileakIsActive() -> Bool { calls += 1; return true }
    func enable(endpoint: String, interfaceName: String) throws { calls += 1 }
    func disable() throws { calls += 1 }
}
let key = Data(repeating: 1, count: 32).base64EncodedString()
let ranges = ["ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts"]
func profile(_ field: String) -> String {
    "[Interface]\nPrivateKey = \(key)\nAddress = 10.64.249.2/32\n\(field)\n[Peer]\nPublicKey = \(key)\nEndpoint = 192.0.2.1:51824\nAllowedIPs = 0.0.0.0/0\n"
}
var invalid: [String?] = [nil, "", profile("PrivateKey = broken"), profile("HeaderProtectionKey = broken"), profile("UnknownCritical = 1"), profile("S1 = 65536"), profile("Jc = 65536"), profile("PreUp = echo nope"), profile("I1 = <unknown>"), profile("I1 = <r nope>"), profile("H1 = 1-3\nH2 = 2-4"), profile("HeaderProtectionKey = \(key)"), profile("Address = invalid"), profile("ListenPort = 65536")]
invalid += [profile("").replacingOccurrences(of: "PublicKey = \(key)", with: "PublicKey = broken"), profile("").replacingOccurrences(of: "192.0.2.1:51824", with: "bad endpoint"), profile("").replacingOccurrences(of: "0.0.0.0/0", with: "no-address"), profile("").replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0", with: "PersistentKeepalive = 1-65536"), profile("").replacingOccurrences(of: "[Peer]", with: "[FutureSection]")]
for field in ranges { for value in ["", "4294967296", "1-4294967296", "10-2", "1--2", "nope"] { invalid.append(profile("\(field) = \(value)")) } }
for field in ["RandomTrailers", "DisableCookies"] { for value in ["", "tru", "true", "false", "unknown"] { invalid.append(profile("\(field) = \(value)")) } }
let paths = HelperPathsLayout()
let previous = HelperSession(interfaceName: "utun42", endpoint: "192.0.2.2:51824", ownerPID: 42, antiLeakArmed: true)
for (index, raw) in invalid.enumerated() {
    let files = Files(); files.texts[paths.activeConfigPath] = "previous-profile"; files.texts[paths.dnsStatePath] = "previous-dns"; files.texts[paths.defaultConfigPath] = raw
    let before = files.texts; let runner = Commands(); let firewall = Firewall()
    let controller = SystemTunnelController(fileSystem: files, paths: paths, runner: runner, firewall: firewall)
    do { _ = try controller.bringUp(currentSession: previous, armAntiLeak: true, ownerPID: 99); fatalError("invalid fixture admitted \(index)") } catch {}
    guard files.texts == before && files.mutations == 0 && runner.calls == 0 && firewall.calls == 0 else { fatalError("pre-admission mutation fixture \(index)") }
}
do {
    let files = Files(); files.texts[paths.defaultConfigPath] = profile(""); files.texts[paths.activeConfigPath] = "previous-profile"; files.unreadable = paths.defaultConfigPath
    let before = files.texts; let runner = Commands(); let firewall = Firewall()
    do { _ = try SystemTunnelController(fileSystem: files, paths: paths, runner: runner, firewall: firewall).bringUp(currentSession: previous, armAntiLeak: true, ownerPID: 99); fatalError("unreadable admitted") } catch {}
    precondition(files.texts == before && files.mutations == 0 && runner.calls == 0 && firewall.calls == 0)
}
print("HELPER_ADMISSION_REJECTIONS=\(invalid.count); UNREADABLE_PROFILE=REJECTED; FILE_COMMAND_FIREWALL_MUTATIONS=0; PREVIOUS_STATE=retained")
var accepted = 0
for field in ranges {
    for value in ["0", "4294967295", "0-4294967295"] { try AwgConfigAdmission.validate(profile("\(field) = \(value)")); accepted += 1 }
}
try AwgConfigAdmission.validate(profile("HeaderProtectionKey = \(key)\nS1 = 12\nS2 = 12\nS3 = 12\nS4 = 12\nI1 = <r 8><t><rc 8>")); accepted += 1
for field in ["RandomTrailers", "DisableCookies"] {
    for token in ["true", "false", "on", "off", "TRUE", "0", "1", "yes", "no", "t", "f"] {
        var lines = [String](); try NativeAwgBoolean.append(field, token, to: &lines)
        try AwgConfigAdmission.validate(profile(lines.joined(separator: "\n"))); accepted += 1
    }
    for token in ["", "nope", "tru"] {
        do {
            var lines = [String](); try NativeAwgBoolean.append(field, token, to: &lines)
            try AwgConfigAdmission.validate(profile(lines.joined(separator: "\n")))
            fatalError("invalid rendered token admitted")
        } catch {}
    }
}
print("HELPER_VALID_PROFILES=\(accepted); MANAGED_BOOLEAN_RENDER_TO_ADMISSION=PASS; INVALID_RENDERED_FLAGS=REJECTED")
