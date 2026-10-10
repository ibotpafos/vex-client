import Darwin
import Foundation
import XCTest
@testable import VEXNativeMac
import VEXHelperCore

final class SwiftHelperContractTests: XCTestCase {
    private func readText(_ relativePath: String) throws -> String {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = rootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSwiftModelBuildsOnlyRecognizedHelperCommandForms() throws {
        let source = try readText("Sources/VEXNativeMac/VEXHelperClient.swift")

        XCTAssertTrue(source.contains("func connect(antiLeakEnabled: Bool) async"))
        XCTAssertTrue(source.contains(#"up owner_pid=\(ProcessInfo.processInfo.processIdentifier)"#))
        XCTAssertTrue(source.contains(#"up-no-antileak owner_pid=\(ProcessInfo.processInfo.processIdentifier)"#))
        XCTAssertTrue(source.contains("func disconnect(releaseAntiLeak: Bool) async"))
        XCTAssertTrue(source.contains("attach-owner owner_pid="))
        XCTAssertTrue(source.contains("func shutdownForAppTermination() async"))
    }

    func testUnknownHelperCommandIsRejectedByHelperProtocol() async throws {
        let server = try SimulatedHelperSocket { command in
            let supportedCommands = ["up", "down", "status", "shutdown", "repair", "diagnostics", "attach-owner", "antileak-off", "up-no-antileak"]
            return supportedCommands.contains(where: { command.hasPrefix($0) }) ? "ok\n" : "error: unknown command test\n"
        }
        defer { server.stop() }

        do {
            try await VEXHelperClient(socketPath: server.path)
                .sendExpectingOK("reconnect", timeoutSeconds: 1)
            XCTFail("unknown helper command should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown command"))
        }
    }

    func testPfUnknownStateIsNotEquivalentToDisabled() throws {
        let source = try readText("Sources/VEXHelperCore/SystemSupport.swift")

        XCTAssertTrue(source.contains("private func pfIsDisabled() throws -> Bool"))
        XCTAssertTrue(source.contains("guard result.succeeded else"))
        XCTAssertTrue(source.contains("pfctl -s info failed with status"))
        XCTAssertTrue(source.contains(#"== "Status: Disabled""#))
        XCTAssertFalse(source.contains("return !result.succeeded"))
    }

    func testFailOpenTeardownKeepsTunnelStateUntilPfDisabled() throws {
        let source = try readText("Sources/VEXHelperCore/SystemSupport.swift")

        guard let actionRange = source.range(of: "public func bringDown(currentSession: HelperSession?) throws {") else {
            return XCTFail("bringDown not found")
        }
        let action = String(source[actionRange.lowerBound...])

        let disableIndex = action.range(of: "try firewall.disable()")?.lowerBound
        let quickDownIndex = action.range(of: "runQuick(\"down\"")?.lowerBound

        XCTAssertNotNil(disableIndex)
        XCTAssertNotNil(quickDownIndex)
        if let disableIndex, let quickDownIndex {
            XCTAssertLessThan(
                action.distance(from: action.startIndex, to: disableIndex),
                action.distance(from: action.startIndex, to: quickDownIndex)
            )
        }
    }

    func testContinuousSupervisorsRunForOwnerAndRoutes() throws {
        let source = try readText("Sources/VEXHelperCore/Runtime.swift")

        XCTAssertTrue(source.contains("startRouteWatchdogLoopIfNeeded()"))
        XCTAssertTrue(source.contains("armOwnerWatchdog"))
        XCTAssertTrue(source.contains("await recoverStrandedAntiLeak()"))
        XCTAssertTrue(source.contains("await resumeOwnerWatchdog()"))
        XCTAssertTrue(source.contains("unhealthyTunnelTicks >= 2"))
        XCTAssertTrue(source.contains("fail-open teardown completed"))
    }

    func testOwnerAuthenticationSessionFlowIsDeclaredInContract() throws {
        let runtime = try readText("Sources/VEXHelperCore/Runtime.swift")
        let auth = try readText("Sources/VEXHelperCore/PeerAuthenticator.swift")

        XCTAssertTrue(runtime.contains("verifiedOwnerPID"))
        XCTAssertTrue(runtime.contains("persistOwnerSession"))
        XCTAssertTrue(runtime.contains("owner_pid \\(requested) does not match socket peer"))
        XCTAssertTrue(auth.contains("LOCAL_PEERTOKEN"))
        XCTAssertTrue(auth.contains("SecCodeCopyGuestWithAttributes"))
        XCTAssertTrue(auth.contains("kSecGuestAttributeAudit as String: peer.auditToken"))
        XCTAssertTrue(auth.contains("SecRequirementCreateWithString(Self.clientRequirement"))
        XCTAssertTrue(auth.contains("SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)"))
        XCTAssertTrue(auth.contains("peer.effectiveUID == consoleUID"))
        XCTAssertEqual(SystemPeerAuthenticator.clientRequirement, VEXHelperInstaller.appSigningRequirement)
        XCTAssertTrue(SystemPeerAuthenticator.clientRequirement.contains(#"certificate leaf = H"c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e""#))
        XCTAssertTrue(SystemPeerAuthenticator.clientRequirement.contains(#"anchor apple generic and certificate leaf[subject.OU] = "3JLW9XNU53""#))
        XCTAssertFalse(auth.contains("ProcessInfo.processInfo.environment"))
    }

    func testShutdownHandlingIsBoundedInSwiftShutdownPath() throws {
        let source = try readText("Sources/VEXNativeMac/VEXHelperClient.swift")

        XCTAssertTrue(source.contains("try await client.sendExpectingOK(\"shutdown\", timeoutSeconds: 2)"))
        XCTAssertTrue(source.contains("func send(_ command: String, timeoutSeconds: Int = 5) async throws -> String"))
    }

    func testConnectRetryKeepsABoundedBringUpTimeout() throws {
        let source = try readText("Sources/VEXNativeMac/VEXHelperClient.swift")

        func section(from start: String, until end: String) throws -> String {
            let startRange = try XCTUnwrap(source.range(of: start))
            let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }
        let retry = try section(from: "private func sendCommandWithRetry(", until: "private func isConnectCommand(")

        // Connect commands stay bounded (15s first attempt, 20s retry); the
        // handshake itself is confirmed by status polling, not a long socket
        // timeout that would delay user-visible failures.
        XCTAssertTrue(retry.contains("timeoutSeconds: isConnectCommand(command) ? 15 : 10"))
        let readiness = try XCTUnwrap(retry.range(of: "try await ensureHelperReady(commandGeneration: generation, shouldConnect: shouldConnect)"))
        let admission = try XCTUnwrap(retry.range(of: "try ensureCurrentHelperCommand(command, generation: generation, shouldConnect: shouldConnect)", range: readiness.upperBound..<retry.endIndex))
        let send = try XCTUnwrap(retry.range(of: "let response = try await client.send(command, timeoutSeconds: 20)", range: admission.upperBound..<retry.endIndex))
        let responseFence = try XCTUnwrap(retry.range(of: "try ensureCurrentHelperCommand(command, generation: generation, shouldConnect: shouldConnect)", range: send.upperBound..<retry.endIndex))
        let returned = try XCTUnwrap(retry.range(of: "return response", range: responseFence.upperBound..<retry.endIndex))
        XCTAssertLessThan(readiness.lowerBound, admission.lowerBound)
        XCTAssertLessThan(admission.lowerBound, send.lowerBound)
        XCTAssertLessThan(send.lowerBound, responseFence.lowerBound)
        XCTAssertLessThan(responseFence.lowerBound, returned.lowerBound)

        let fence = try section(from: "private func ensureCurrentHelperCommand(", until: "private func confirmConnect(")
        XCTAssertTrue(fence.contains("helperCommandGeneration == generation"))
        XCTAssertTrue(fence.contains("!isConnectCommand(command) || (!Task.isCancelled && shouldConnect())"))
    }

    func testShutdownPathTimeoutIsObservableAtTransportLevel() async throws {
        let server = try SimulatedHelperSocket(responseDelay: 3, response: { _ in nil })
        defer { server.stop() }

        let started = ContinuousClock.now
        do {
            try await VEXHelperClient(socketPath: server.path)
                .sendExpectingOK("shutdown", timeoutSeconds: 1)
            XCTFail("shutdown should time out")
        } catch {
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            XCTAssertTrue(error is VEXHelperError)
        }
    }

    func testInstallerReferencesPackagedSwiftHelperBinaryAndProgramArguments() throws {
        let installerScript = try readText("HelperResources/install-vex-vpn-helper.sh")
        let wrapperScript = try readText("../scripts/install_native_macos_helper_from_app.sh")
        let swiftInstaller = try readText("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let runtimeVerifier = try readText("../scripts/verify_native_macos_runtime.sh")
        let appSource = try readText("Sources/VEXNativeMac/VEXNativeMacApp.swift")

        XCTAssertTrue(installerScript.contains("<string>$helper_dir/vex-helper</string>"))
        XCTAssertTrue(installerScript.contains("for required in awg amneziawg-go vex-helper; do"))
        XCTAssertTrue(installerScript.contains("VEX_EXPECTED_TEAM_ID"))
        XCTAssertTrue(installerScript.contains("rollback_install"))
        XCTAssertTrue(installerScript.contains("root-owned verified app snapshot"))
        XCTAssertTrue(installerScript.contains(#"codesign --verify --deep --strict -R="$app_requirement" "$verified_app""#))
        XCTAssertTrue(wrapperScript.contains("resource_dir=\"${APP_PATH}/Contents/Resources/resources\""))
        XCTAssertTrue(wrapperScript.contains("/usr/bin/ditto"))
        XCTAssertTrue(wrapperScript.contains("\\$verified_resources/install-vex-vpn-helper.sh"))
        XCTAssertTrue(swiftInstaller.contains("/Library/Application Support/VEX VPN/helper"))
        XCTAssertTrue(swiftInstaller.contains("vex-helper"))
        XCTAssertTrue(swiftInstaller.contains("/usr/bin/ditto"))
        XCTAssertTrue(swiftInstaller.contains("verified_resources"))
        XCTAssertTrue(swiftInstaller.contains("certificate leaf[subject.OU]"))
        XCTAssertTrue(swiftInstaller.contains(#""--verify", "--deep", "--strict", "-R=\(Self.appSigningRequirement)", Bundle.main.bundleURL.path"#))
        XCTAssertFalse(swiftInstaller.contains("SecCodeCopySelf"))
        XCTAssertFalse(swiftInstaller.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(swiftInstaller.contains("/tmp/vex-vpn-install.log"))
        XCTAssertTrue(wrapperScript.contains("certificate leaf[subject.OU]"))
        XCTAssertTrue(wrapperScript.contains("app_requirement='" + SystemPeerAuthenticator.clientRequirement + "'"))
        XCTAssertTrue(wrapperScript.contains(#"codesign --verify --deep --strict -R="${app_requirement}" "${APP_PATH}""#))
        XCTAssertFalse(wrapperScript.contains("INSTALL_LOG"))
        XCTAssertTrue(runtimeVerifier.contains("KeepAlive raw"))
        XCTAssertTrue(runtimeVerifier.contains("helper_plist_is_persistent"))
        XCTAssertTrue(runtimeVerifier.contains("--helper-status-probe"))
        XCTAssertFalse(runtimeVerifier.contains("/usr/bin/nc"))
        XCTAssertTrue(appSource.contains("CommandLine.arguments.contains(\"--helper-status-probe\")"))
        XCTAssertTrue(appSource.contains("sendUnixSocketCommand("))
        XCTAssertFalse(wrapperScript.contains("/Library/Application Support/VEX VPN/helper/awg"))
    }
}

private final class SimulatedHelperSocket: @unchecked Sendable {
    let path: String

    private let listener: Int32
    private let responseDelay: UInt32
    private let response: @Sendable (String) -> String?
    private let worker = DispatchGroup()
    private let lock = NSLock()
    private var receivedCommand: String?

    init(
        responseDelay: UInt32 = 0,
        response: @escaping @Sendable (String) -> String?
    ) throws {
        path = "/tmp/vex-helper-contract-\(UUID().uuidString.prefix(8)).sock"
        self.responseDelay = responseDelay
        self.response = response
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    maxPathLength
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        worker.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { worker.leave() }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }

            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1 {
                if byte == 10 { break }
                bytes.append(byte)
            }

            let command = String(decoding: bytes, as: UTF8.self)
            lock.lock()
            receivedCommand = command
            lock.unlock()

            if responseDelay > 0 {
                sleep(responseDelay)
            }

            guard let payload = response(command) else { return }
            payload.withCString { pointer in
                _ = Darwin.write(client, pointer, strlen(pointer))
            }
        }
    }

    func stop() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = worker.wait(timeout: .now() + 3)
        unlink(path)
    }
}
