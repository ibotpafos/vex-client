import Foundation

final class Files: HelperFileSystem, @unchecked Sendable {
    var texts: [String: String] = [:]
    var mutations = 0
    var unreadable: String?
    var rejectDirectory = false
    func createDirectory(at path: String) throws {
        if rejectDirectory { throw HelperError.writeFailed("isolated directory failure") }
        mutations += 1
    }
    func fileExists(at path: String) -> Bool { texts[path] != nil }
    func fileSize(at path: String) -> UInt64? { texts[path].map { UInt64($0.utf8.count) } }
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

final class Events { var values = [String]() }
final class FixtureCommands: CommandRunning, @unchecked Sendable {
    let events: Events
    var calls = [CommandSpec]()
    var reject = false
    init(_ events: Events) { self.events = events }
    func run(_ spec: CommandSpec) throws -> CommandResult {
        events.values.append(spec.arguments.first ?? spec.program)
        calls.append(spec)
        if reject { throw HelperError.commandFailed("isolated command failure") }
        return CommandResult(status: 0)
    }
}
final class FixtureFirewall: PFFirewallControlling, @unchecked Sendable {
    let events: Events
    init(_ events: Events) { self.events = events }
    func antileakIsActive() -> Bool { true }
    func enable(endpoint: String, interfaceName: String) throws {}
    func disable() throws { events.values.append("release-filter") }
}
do {
    let events = Events(), files = Files()
    files.texts[paths.activeConfigPath] = profile("")
    files.texts[paths.dnsStatePath] = "\n"
    let runner = FixtureCommands(events)
    let controller = SystemTunnelController(fileSystem: files, paths: paths, runner: runner, firewall: FixtureFirewall(events))
    try controller.bringDown(currentSession: previous)
    precondition(events.values.first == "down" && events.values.last == "release-filter", "filter released before confirmed teardown")
}
do {
    let events = Events(), files = Files()
    files.texts[paths.activeConfigPath] = profile("")
    let runner = FixtureCommands(events); runner.reject = true
    let controller = SystemTunnelController(fileSystem: files, paths: paths, runner: runner, firewall: FixtureFirewall(events))
    do { try controller.bringDown(currentSession: previous); fatalError("failed stop was accepted") } catch {}
    precondition(!events.values.contains("release-filter"), "failed stop released protection")
}
do {
    let events = Events(), files = Files()
    files.texts[paths.activeConfigPath] = profile("")
    files.texts[paths.routingParametersPath] = "owned-routing-parameters"
    let before = files.texts
    let controller = SystemTunnelController(fileSystem: files, paths: paths, runner: FixtureCommands(events), firewall: FixtureFirewall(events))
    try controller.bringDownPreservingProtection(currentSession: previous)
    precondition(events.values == ["--stop-transport"] && files.texts == before, "protected stop released capture, DNS or filter")
}
for fail in [false, true] {
    let files = Files(), runner = FixtureCommands(Events())
    runner.reject = fail
    files.texts[paths.routingParametersPath] = "owned-routing-parameters"
    files.texts[paths.pfConfigPath] = "anchor \"com.vexguard.antileak\"\nload anchor \"com.vexguard.antileak\" from \"\(paths.antileakAnchorPath)\"\n"
    let firewall = SystemPFFirewallController(runner: runner, fileSystem: files, paths: paths)
    do { try firewall.enable(endpoint: "192.0.2.1:51824", interfaceName: "utun42") }
    catch { precondition(fail) }
    let rules = files.texts[paths.antileakAnchorPath] ?? ""
    precondition(rules.contains("user _vexvpn") && rules.contains("block drop out all"), "routed filter missing protected owner/default Block")
    precondition(!rules.contains("192.0.2.1") && !runner.calls.contains { $0.arguments.contains("-F") }, "routed filter allowed arbitrary endpoint egress or failed open")
}
print("HELPER_ROUTING_PROTECTION=PASS; STOP_RECEIPT_BEFORE_RESTORE=PASS; FAILED_ARM_AND_STOP=retained")

do {
    let events = Events(), files = Files()
    files.rejectDirectory = true
    let runtime = HelperRuntime(
        store: HelperStateStore(fileSystem: files, paths: paths),
        tunnelController: SystemTunnelController(fileSystem: files, paths: paths, runner: FixtureCommands(events), firewall: FixtureFirewall(events)),
        firewallController: FixtureFirewall(events), processInspector: SystemProcessInspector()
    )
    do { try await runtime.bootstrap(); fatalError("unwritable store was accepted") } catch {}
    precondition(events.values.isEmpty, "bootstrap storage error released protection")
}
do {
    let events = Events(), files = Files()
    files.texts[paths.sessionStatePath] = previous.payload
    files.texts[paths.ownerSessionPath] = OwnerSession(pid: Int32.max, token: "fixture", identity: "retired").payload
    let runtime = HelperRuntime(
        store: HelperStateStore(fileSystem: files, paths: paths),
        tunnelController: SystemTunnelController(fileSystem: files, paths: paths, runner: FixtureCommands(events), firewall: FixtureFirewall(events)),
        firewallController: FixtureFirewall(events), processInspector: SystemProcessInspector()
    )
    await runtime.runOwnerWatchdogTick()
    await runtime.runRouteWatchdogTick()
    await runtime.runRouteWatchdogTick()
    await runtime.recoverStrandedAntiLeak()
    precondition(files.texts[paths.sessionStatePath] != nil && events.values.isEmpty, "watchdog/crash recovery released requested protection")
}
print("HELPER_BOOTSTRAP_AND_WATCHDOG_FAILURES=retained")
