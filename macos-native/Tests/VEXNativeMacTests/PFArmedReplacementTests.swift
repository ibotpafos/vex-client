import XCTest
@testable import VEXHelperCore

final class PFArmedReplacementTests: XCTestCase {
    func testReplacementKeepsPFArmedAndDoesNotUseGlobalOrToggleCommands() throws {
        let fixture = Fixture()
        let controller = fixture.controller()

        try controller.updateWhileArmed(endpoint: "198.51.100.8:51820", interfaceName: "utun7")

        XCTAssertTrue(fixture.files[fixture.paths.antileakAnchorPath]?.contains("198.51.100.8") == true)
        XCTAssertEqual(fixture.files[fixture.paths.antileakStatePath], "status=active\nendpoint=198.51.100.8:51820\niface=utun7\n")
        XCTAssertNil(fixture.files[fixture.paths.legacyAntileakStatePath])
        XCTAssertEqual(fixture.runner.calls.filter { $0.arguments == ["-a", "com.vexguard.antileak", "-f", fixture.paths.antileakAnchorPath] }.count, 1)
        XCTAssertTrue(fixture.runner.runtime.contains("198.51.100.8"))
        XCTAssertFalse(fixture.runner.calls.contains { $0.arguments.contains("-E") || $0.arguments.contains("-D") || $0.arguments.contains("-F") })
        XCTAssertFalse(fixture.runner.calls.contains { $0.arguments == ["-f", fixture.paths.pfConfigPath] })
    }

    func testFailedAnchorLoadRestoresRulesAndPersistentMarkersWithoutDisablingPF() throws {
        let fixture = Fixture(loadStatus: 1)
        let controller = fixture.controller()
        let previousRules = fixture.files[fixture.paths.antileakAnchorPath]
        let previousState = fixture.files[fixture.paths.antileakStatePath]
        let previousLegacy = fixture.files[fixture.paths.legacyAntileakStatePath]

        XCTAssertThrowsError(try controller.updateWhileArmed(endpoint: "198.51.100.8:51820", interfaceName: "utun7"))

        XCTAssertEqual(fixture.files[fixture.paths.antileakAnchorPath], previousRules)
        XCTAssertEqual(fixture.files[fixture.paths.antileakStatePath], previousState)
        XCTAssertEqual(fixture.files[fixture.paths.legacyAntileakStatePath], previousLegacy)
        XCTAssertEqual(fixture.runner.runtime, FakeRunner.displayed(previousRules!))
        XCTAssertEqual(fixture.runner.calls.filter { $0.arguments == ["-a", "com.vexguard.antileak", "-f", fixture.paths.antileakAnchorPath] }.count, 2)
        XCTAssertFalse(fixture.runner.calls.contains { $0.arguments.contains("-E") || $0.arguments.contains("-D") || $0.arguments.contains("-F") })
    }

    func testDisabledPFOrInvalidEndpointRefusesBeforeWritingAnchor() throws {
        let fixture = Fixture(enabled: false)
        let initial = fixture.files

        XCTAssertThrowsError(try fixture.controller().updateWhileArmed(endpoint: "198.51.100.8:51820", interfaceName: "utun7"))
        XCTAssertEqual(fixture.files, initial)

        let invalid = Fixture()
        let invalidInitial = invalid.files
        XCTAssertThrowsError(try invalid.controller().updateWhileArmed(endpoint: "bad endpoint; block all", interfaceName: "utun7"))
        XCTAssertEqual(invalid.files, invalidInitial)
        XCTAssertTrue(invalid.runner.calls.isEmpty)
    }
}

private final class Fixture: @unchecked Sendable {
    let paths: HelperPathsLayout
    let runner: FakeRunner
    let fileSystem: FakeFileSystem

    var files: [String: String] { fileSystem.files }

    init(enabled: Bool = true, loadStatus: Int32 = 0) {
        paths = HelperPathsLayout(
            helperDirectory: "/fixture/helper", antileakStatePath: "/fixture/antileak.state",
            legacyAntileakStatePath: "/fixture/antileak.active", antileakAnchorPath: "/fixture/anchor",
            pfConfigPath: "/fixture/pf.conf"
        )
        fileSystem = FakeFileSystem([
            paths.antileakAnchorPath: "set block-policy drop\npass quick on lo0 all\npass out quick on utun7 all\npass out quick inet proto udp from any to 198.51.100.7 port = 51820 keep state\npass out quick inet proto tcp from any to 198.51.100.7 port = 443 keep state\npass out quick inet proto tcp from any to 198.51.100.7 port = 22 keep state\nblock drop out all\n",
            paths.antileakStatePath: "status=active\nendpoint=198.51.100.7:51820\niface=utun7\n",
            paths.legacyAntileakStatePath: "legacy\n",
            paths.pfConfigPath: "anchor \"com.vexguard.antileak\"\nload anchor \"com.vexguard.antileak\" from \"/fixture/anchor\"\n",
        ])
        runner = FakeRunner(enabled: enabled, loadStatus: loadStatus, files: fileSystem)
    }

    func controller() -> SystemPFFirewallController {
        SystemPFFirewallController(runner: runner, fileSystem: fileSystem, paths: paths)
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    private(set) var calls: [CommandSpec] = []
    private var loadStatus: Int32
    private let enabled: Bool
    private let files: FakeFileSystem
    private(set) var runtime: String

    init(enabled: Bool, loadStatus: Int32, files: FakeFileSystem) {
        self.enabled = enabled; self.loadStatus = loadStatus; self.files = files
        runtime = Self.displayed(files.files["/fixture/anchor"]!)
    }

    static func displayed(_ anchor: String) -> String {
        anchor.split(separator: "\n").filter { !$0.hasPrefix("set ") }.joined(separator: "\n") + "\n"
    }

    func run(_ spec: CommandSpec) throws -> CommandResult {
        calls.append(spec)
        if spec.arguments == ["-s", "info"] {
            return CommandResult(status: 0, stdout: enabled ? "Status: Enabled\n" : "Status: Disabled\n")
        }
        if spec.arguments == ["-a", "com.vexguard.antileak", "-sr"] {
            return CommandResult(status: 0, stdout: runtime)
        }
        if spec.arguments == ["-a", "com.vexguard.antileak", "-f", "/fixture/anchor"] {
            let status = loadStatus
            loadStatus = 0
            if status == 0 { runtime = Self.displayed(files.files["/fixture/anchor"]!) }
            return CommandResult(status: status)
        }
        XCTFail("unexpected command: \(spec.arguments)")
        return CommandResult(status: 1)
    }
}

private final class FakeFileSystem: HelperFileSystem, @unchecked Sendable {
    private(set) var files: [String: String]
    init(_ files: [String: String]) { self.files = files }
    func createDirectory(at path: String) throws {}
    func fileExists(at path: String) -> Bool { files[path] != nil }
    func fileSize(at path: String) -> UInt64? { files[path].map { UInt64($0.utf8.count) } }
    func modificationDate(at path: String) -> Date? { nil }
    func readText(at path: String) throws -> String { guard let text = files[path] else { throw HelperError.io("missing \(path)") }; return text }
    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws { files[path] = text }
    func removeItem(at path: String) throws { files.removeValue(forKey: path) }
}
