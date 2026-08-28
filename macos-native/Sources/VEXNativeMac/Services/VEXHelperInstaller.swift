import AppKit
import CryptoKit
import Foundation
import Security

struct VEXHelperInstaller {
    typealias ProgressHandler = @MainActor @Sendable (VEXHelperInstallationPhase) -> Void

    private let helperDir = "/Library/Application Support/VEX VPN/helper"
    private let helperPlist = "/Library/LaunchDaemons/app.vex.vpn.helper.plist"
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
        try await installWithAdminPrivileges()
        if await waitForSocket(timeout: 8.0) {
            return
        }
        throw VEXHelperInstallError.socketUnavailableAfterInstall
    }

    func repairWithAdminPrivileges(
        progress: ProgressHandler? = nil
    ) async throws {
        if let progress {
            await progress(.preparing)
        }
        await prepareInteractiveInstall()
        if let progress {
            await progress(.authorizing)
        }
        try await installWithAdminPrivileges(progress: progress)
        if let progress {
            await progress(.verifying)
        }
        if !(await waitForSocket(timeout: 8.0)) {
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
              fm.fileExists(atPath: "\(helperDir)/awg-quick.sh"),
              installedVersion.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion,
              helperPlistIsCurrent,
              helperBinarySignatureIsValid,
              resourceMatchesInstalled("vex-helper"),
              resourceMatchesInstalled("amneziawg-go"),
              resourceMatchesInstalled("awg"),
              resourceMatchesInstalled("awg-quick.sh") else {
            return false
        }
        return true
    }

    private var installedVersion: String {
        (try? String(contentsOfFile: "\(helperDir)/version", encoding: .utf8)) ?? ""
    }

    private var helperVersion: String {
        guard let url = try? resourceFile("helper-version"),
              let value = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var helperPlistIsCurrent: Bool {
        guard let data = FileManager.default.contents(atPath: helperPlist),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = plist as? [String: Any],
              dictionary["RunAtLoad"] as? Bool == true else {
            return false
        }
        return helperPlistKeepsServiceAvailable(dictionary)
    }

    private func helperPlistKeepsServiceAvailable(_ plist: [String: Any]) -> Bool {
        plist["KeepAlive"] as? Bool == true
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
        guard let response = try? sendUnixSocketCommand("status", socketPath: client.socketPath) else {
            return false
        }
        return response.hasPrefix("state=")
            && response.contains("operation_in_progress=")
            && !response.hasPrefix("error:")
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
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return socketIsConnectable
    }

    @MainActor
    private func prepareInteractiveInstall() async {
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if NSApp.isActive {
                break
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        do {
            try await Task.sleep(nanoseconds: 50_000_000)
        } catch {
            return
        }
    }

    private func installWithAdminPrivileges(
        progress: ProgressHandler? = nil
    ) async throws {
        guard verifyCurrentAppBundleSignature() else {
            throw VEXHelperError.commandFailed("Проверка целостности подписи приложения не пройдена.")
        }
        _ = try resourceFile("install-vex-vpn-helper.sh")
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vex", isDirectory: true)
            .appendingPathComponent("vex.conf")
        let user = NSUserName()
        guard let signingIdentity = currentAppSigningIdentity() else {
            throw VEXHelperError.commandFailed("Не удалось определить подпись приложения для безопасной установки helper.")
        }
        let appBundle = Bundle.main.bundleURL.path
        let appRequirement: String
        let identityEnvironment: String
        if let teamIdentifier = signingIdentity.teamIdentifier {
            appRequirement = "anchor apple generic and identifier \"app.vex.vpn.native\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            identityEnvironment = "VEX_EXPECTED_TEAM_ID=\(shellQuote(teamIdentifier))"
        } else if let certificateSHA1 = signingIdentity.certificateSHA1,
                  let certificateSHA256 = signingIdentity.certificateSHA256 {
            appRequirement = "identifier \"app.vex.vpn.native\" and certificate leaf = H\"\(certificateSHA1)\""
            identityEnvironment = "VEX_EXPECTED_CERT_SHA256=\(shellQuote(certificateSHA256))"
        } else {
            throw VEXHelperError.commandFailed("Подпись приложения не содержит проверяемую идентичность VEX.")
        }
        let shellCommand = [
            "set -euo pipefail",
            "verified_root=$(/usr/bin/mktemp -d /var/tmp/vex-install-app.XXXXXX)",
            "trap '/bin/rm -rf \"$verified_root\"' EXIT",
            "/usr/bin/ditto \(shellQuote(appBundle)) \"$verified_root/VEX Native.app\"",
            "verified_app=\"$verified_root/VEX Native.app\"",
            "/usr/bin/codesign --verify --deep --strict -R=\(shellQuote(appRequirement)) \"$verified_app\"",
            "verified_resources=\"$verified_app/Contents/Resources/resources\"",
            "\(identityEnvironment) /bin/bash \"$verified_resources/install-vex-vpn-helper.sh\" \"$verified_resources\" \(shellQuote(configPath.path)) \(shellQuote(user)) \"$verified_app\"",
        ].joined(separator: "; ")
        let appleScript = "do shell script \"\(appleScriptString(shellCommand))\" with administrator privileges with prompt \"VEX Inc. устанавливает системный компонент VEX\""
        let phaseTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled, let progress else { return }
            await progress(.installing)
        }
        defer { phaseTask.cancel() }

        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout
            try process.run()
            process.waitUntilExit()
            return AdminInstallResult(
                terminationStatus: process.terminationStatus,
                standardError: String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "",
                standardOutput: String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            )
        }.value

        guard result.terminationStatus == 0 else {
            let message = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? result.standardOutput : result.standardError
            if message.localizedCaseInsensitiveContains("cancel") || message.contains("отмен") {
                throw VEXHelperInstallError.cancelled
            }
            throw VEXHelperInstallError.installFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func currentAppSigningIdentity() -> AppSigningIdentity? {
        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(runningCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let signing = information as? [String: Any],
              signing[kSecCodeInfoIdentifier as String] as? String == "app.vex.vpn.native" else {
            return nil
        }
        if let teamIdentifier = signing[kSecCodeInfoTeamIdentifier as String] as? String,
           !teamIdentifier.isEmpty {
            return AppSigningIdentity(teamIdentifier: teamIdentifier)
        }
        guard let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return nil
        }
        let leafData = SecCertificateCopyData(leaf) as Data
        return AppSigningIdentity(
            certificateSHA1: Insecure.SHA1.hash(data: leafData).hexString,
            certificateSHA256: SHA256.hash(data: leafData).hexString
        )
    }

    private func verifyCurrentAppBundleSignature() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", Bundle.main.bundleURL.path]
        return (try? process.runAndWait()) == 0
    }

    private func resourceFile(_ name: String) throws -> URL {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("resources").appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent(name),
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

private struct AdminInstallResult: Sendable {
    let terminationStatus: Int32
    let standardError: String
    let standardOutput: String
}

private struct AppSigningIdentity {
    var teamIdentifier: String?
    var certificateSHA1: String?
    var certificateSHA256: String?

    init(
        teamIdentifier: String? = nil,
        certificateSHA1: String? = nil,
        certificateSHA256: String? = nil
    ) {
        self.teamIdentifier = teamIdentifier
        self.certificateSHA1 = certificateSHA1
        self.certificateSHA256 = certificateSHA256
    }
}

private extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
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
