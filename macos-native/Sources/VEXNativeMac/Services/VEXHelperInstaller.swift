import AppKit
import CryptoKit
import Foundation

struct VEXHelperInstaller {
    private let helperDir = "/Library/Application Support/VEX VPN/helper"
    private let helperPlist = "/Library/LaunchDaemons/app.vex.vpn.helper.plist"
    private let helperVersion = "31"
    private let launchdLabel = "app.vex.vpn.helper"
    private let socketPath = "/var/run/vex-helper.sock"

    func ensureReady(allowAdminInstall: Bool = true) async throws {
        let currentFilesInstalled = filesAreCurrent

        if socketIsConnectable && currentFilesInstalled {
            return
        }

        if currentFilesInstalled {
            if socketIsConnectable {
                return
            }
            removeStaleSocket()
            try await kickstart()
            if await waitForSocket(timeout: 2.0) {
                return
            }
            throw VEXHelperInstallError.socketUnavailableAfterKickstart
        }

        guard allowAdminInstall else {
            throw VEXHelperInstallError.adminInstallRequired
        }

        await prepareInteractiveInstall()
        try installWithAdminPrivileges()
        if await waitForSocket(timeout: 2.0) {
            return
        }
        throw VEXHelperInstallError.socketUnavailableAfterInstall
    }

    func repairWithAdminPrivileges() async throws {
        await prepareInteractiveInstall()
        try installWithAdminPrivileges()
        if !(await waitForSocket(timeout: 2.0)) {
            throw VEXHelperInstallError.socketUnavailableAfterInstall
        }
    }

    var installedState: VEXHelperInstallState {
        VEXHelperInstallState(
            version: installedVersion,
            filesCurrent: filesAreCurrent,
            socketConnectable: socketIsConnectable,
            helperPath: "\(helperDir)/vex-helper"
        )
    }

    private var filesAreCurrent: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperPlist),
              fm.fileExists(atPath: "\(helperDir)/vex-helper"),
              fm.fileExists(atPath: "\(helperDir)/amneziawg-go"),
              fm.fileExists(atPath: "\(helperDir)/awg"),
              installedVersion.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion,
              helperPlistIsCurrent,
              helperBinarySignatureIsValid,
              resourceMatchesInstalled("vex-helper"),
              resourceMatchesInstalled("amneziawg-go"),
              resourceMatchesInstalled("awg") else {
            return false
        }
        return true
    }

    private var installedVersion: String {
        (try? String(contentsOfFile: "\(helperDir)/version", encoding: .utf8)) ?? ""
    }

    private var helperPlistIsCurrent: Bool {
        guard let plist = try? String(contentsOfFile: helperPlist, encoding: .utf8) else { return false }
        return plistValueIsTrue("RunAtLoad", in: plist)
            && plistValueIsTrue("KeepAlive", in: plist)
    }

    private func plistValueIsTrue(_ key: String, in plist: String) -> Bool {
        let pattern = "<key>\(key)</key>"
        guard let keyRange = plist.range(of: pattern) else { return false }
        let suffix = plist[keyRange.upperBound...].prefix(80)
        return suffix.contains("<true/>")
    }

    private var helperBinarySignatureIsValid: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "--verbose=2", "\(helperDir)/vex-helper"]
        return (try? process.runAndWait()) == 0
    }

    private func resourceMatchesInstalled(_ name: String) -> Bool {
        guard let bundled = try? resourceFile(name) else {
            return false
        }
        let installed = URL(fileURLWithPath: helperDir).appendingPathComponent(name)
        return sha256Hex(bundled) == sha256Hex(installed)
    }

    private func sha256Hex(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var socketIsConnectable: Bool {
        let client = VEXHelperClient(socketPath: socketPath)
        return (try? sendUnixSocketCommand("status", socketPath: client.socketPath)) != nil
    }

    private func removeStaleSocket() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func kickstart() async throws {
        _ = try? await runProcess("/bin/launchctl", arguments: ["bootstrap", "system", helperPlist])
        _ = try? await runProcess("/bin/launchctl", arguments: ["kickstart", "-k", "system/\(launchdLabel)"])
    }

    private func waitForSocket(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketIsConnectable {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return socketIsConnectable
    }

    @MainActor
    private func prepareInteractiveInstall() async {
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if NSApp.isActive {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            NSApp.activate(ignoringOtherApps: true)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func installWithAdminPrivileges() throws {
        let installer = try resourceFile("install-vex-vpn-helper.sh")
        let resourceDir = installer.deletingLastPathComponent()
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vex", isDirectory: true)
            .appendingPathComponent("vex.conf")
        let user = NSUserName()
        let shellCommand = "/bin/bash \(shellQuote(installer.path)) \(shellQuote(resourceDir.path)) \(shellQuote(configPath.path)) \(shellQuote(user))"
        let appleScript = "do shell script \"\(appleScriptString(shellCommand)) > /tmp/vex-vpn-install.log 2>&1\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
            if message.localizedCaseInsensitiveContains("cancel") || message.contains("отмен") {
                throw VEXHelperInstallError.cancelled
            }
            throw VEXHelperInstallError.installFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func resourceFile(_ name: String) throws -> URL {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("resources").appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent()
                .appendingPathComponent("src-tauri/resources")
                .appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../src-tauri/resources")
                .appendingPathComponent(name),
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }
        throw VEXHelperInstallError.missingResource(name)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runProcess(_ executable: String, arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}

struct VEXHelperInstallState: Equatable {
    var version: String
    var filesCurrent: Bool
    var socketConnectable: Bool
    var helperPath: String
}

enum VEXHelperInstallError: LocalizedError {
    case missingResource(String)
    case cancelled
    case installFailed(String)
    case adminInstallRequired
    case socketUnavailableAfterKickstart
    case socketUnavailableAfterInstall

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Не найден bundled helper resource: \(name)."
        case .cancelled:
            return "Установка helper отменена пользователем."
        case .installFailed(let message):
            return message.isEmpty ? "Не удалось установить VPN helper." : message
        case .adminInstallRequired:
            return "VPN helper требует установки. Пароль администратора понадобится только при подключении или установке пакета."
        case .socketUnavailableAfterKickstart:
            return "VPN helper установлен, но сокет не поднялся после launchctl kickstart."
        case .socketUnavailableAfterInstall:
            return "VPN helper установился, но сокет не поднялся."
        }
    }
}

private extension Process {
    func runAndWait() throws -> Int32 {
        try run()
        waitUntilExit()
        return terminationStatus
    }
}
