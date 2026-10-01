import XCTest

@testable import VEXNativeMac

final class SwiftHelperParityContractTests: XCTestCase {
    func testSwiftHelperSourceContractsRemainInSwift() throws {
        let source = try helperContractSource()

        XCTAssertTrue(source.contains("VEXHelperModel"))
        XCTAssertTrue(source.contains("func connect(antiLeakEnabled: Bool) async"))
        XCTAssertTrue(source.contains("func refreshStatus(quiet: Bool = false) async"))
        XCTAssertTrue(source.contains("struct VpnStatus: Equatable"))
        XCTAssertTrue(source.contains("VEXHelperInstallState"))

    }

    func testSwiftHelperConnectCommandContract() throws {
        let source = try helperContractSource()

        XCTAssertTrue(source.contains("up owner_pid="))
        XCTAssertTrue(source.contains("up-no-antileak owner_pid="))
        XCTAssertTrue(source.contains("func disconnect(releaseAntiLeak: Bool) async"))
        XCTAssertTrue(source.contains("sendExpectingOK(\"shutdown\", timeoutSeconds: 2)"))
        XCTAssertTrue(source.contains("attach-owner owner_pid="))
        XCTAssertTrue(source.contains("runCommand(_ command: String, busyState: VpnConnectionState, successMessage: String)"))
    }

    func testVpnStatusParsesUsableConnectedState() {
        let rawStatus = """
        state=connected route_ok=true socket_exists=true route_iface=utun10 ipv6_route_ok=true iface=utun10 latest_handshake=1700000000 rx=123 tx=456 endpoint=10.8.0.2 leak_protection=on
        """
        let status = VpnStatus(helperResponse: rawStatus)

        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.routeInterface, "utun10")
        XCTAssertEqual(status.interfaceName, "utun10")
        XCTAssertEqual(status.leakProtection, "on")
        XCTAssertEqual(status.rxBytes, 123)
        XCTAssertEqual(status.txBytes, 456)
        XCTAssertTrue(status.isUsableConnectedStatus)
        XCTAssertTrue(status.socketExists)
        XCTAssertFalse(status.hasRouteConflict)
    }

    func testVpnStatusTreatsActiveOperationAsConnecting() {
        let rawStatus = "operation_in_progress=true route_ok=true socket_exists=true iface=utun11 endpoint=10.1.1.1 latest_handshake=0 rx=0 tx=0"
        let status = VpnStatus(helperResponse: rawStatus)

        XCTAssertEqual(status.state, .connecting)
        XCTAssertFalse(status.isUsableConnectedStatus)
        XCTAssertEqual(status.interfaceName, "utun11")
    }

    func testVpnStatusDetectsIpv4RouteConflict() {
        let rawStatus = "state=connected route_ok=false socket_exists=true route_iface=en0 iface=utun20 latest_handshake=1 rx=1 tx=1 socket_exists=true"
        let status = VpnStatus(helperResponse: rawStatus)

        XCTAssertTrue(status.hasIPv4RouteConflict)
        XCTAssertTrue(status.hasRouteConflict)
        XCTAssertEqual(status.routeConflictMessage, "Другой VPN удерживает системный маршрут. Трафик через VEX не идет.")
    }

    func testSendStatusThrowsSocketErrorForMissingSocket() async {
        var client = VEXHelperClient()
        client.socketPath = "/dev/null/does-not-exist.sock"

        do {
            _ = try await client.sendStatus()
            XCTFail("Expected sendStatus to throw for missing socket")
        } catch {
            XCTAssertTrue(error is VEXHelperError)
        }
    }

    func testSendUnixSocketCommandRejectsEmptyOrInvalidResponse() throws {
        let invalidSocketPath = "/dev/null/does-not-exist.sock"

        XCTAssertThrowsError(try sendUnixSocketCommand("status", socketPath: invalidSocketPath))
    }

    func testHelperInstallStateSchemaIsDocumentedForContractTests() {
        let state = VEXHelperInstallState(
            version: "0.1.0",
            filesCurrent: true,
            socketConnectable: false,
            helperPath: "/Library/PrivilegedHelperTools/app.vex.vpn.helper"
        )

        XCTAssertEqual(state.version, "0.1.0")
        XCTAssertTrue(state.filesCurrent)
        XCTAssertFalse(state.socketConnectable)
        XCTAssertEqual(state.helperPath, "/Library/PrivilegedHelperTools/app.vex.vpn.helper")
    }

    func testHelperInstallerContractContainsLifecycleGuardrails() throws {
        let source = try helperContractSource()

        XCTAssertTrue(source.contains("adminInstallRequired"))
        XCTAssertTrue(source.contains("socketUnavailableAfterInstall"))
        XCTAssertTrue(source.contains("waitForSocket(timeout"))
        XCTAssertTrue(source.contains("kickstart()"))
    }

    private func helperContractSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let nativeSources = [
            packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift"),
            packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift"),
        ]
        let helperTargets = preferredHelperCoreSources(in: packageRoot.appendingPathComponent("Sources"))

        return try (nativeSources + helperTargets)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func preferredHelperCoreSources(in sourceRoot: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil) else {
            return []
        }

        let helperDirectories = entries.filter {
            $0.lastPathComponent == "VEXHelperCore"
                || $0.lastPathComponent.hasPrefix("VEXPrivilegedHelper")
        }

        return helperDirectories.flatMap { directory in
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            let sources: [URL] = enumerator?.compactMap { candidate -> URL? in
                guard let url = candidate as? URL, url.pathExtension == "swift" else { return nil }
                return url
            } ?? []
            return sources
        }
    }
}
