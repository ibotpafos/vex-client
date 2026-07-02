import Foundation
import SwiftUI

@MainActor
final class VEXHelperModel: ObservableObject {
    @Published private(set) var status = VpnStatus.disconnected
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var installState: VEXHelperInstallState?

    private let client = VEXHelperClient()
    private let installer = VEXHelperInstaller()
    private var pollTask: Task<Void, Never>?
    private var consecutiveStatusFailures = 0

    func start() async {
        installState = installer.installedState
        do {
            try await installer.ensureReady(allowAdminInstall: false)
            installState = installer.installedState
            await detachOwnerWatchdog()
        } catch {
            installState = installer.installedState
            message = error.localizedDescription
        }
        await refreshStatus()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refreshStatus(quiet: true)
            }
        }
    }

    func refreshStatus(quiet: Bool = false) async {
        do {
            let response = try await client.sendStatus()
            status = VpnStatus(helperResponse: response)
            consecutiveStatusFailures = 0
            if !quiet {
                message = nil
            }
        } catch {
            consecutiveStatusFailures += 1
            if consecutiveStatusFailures >= 3 {
                status = .disconnected
            }
            if !quiet {
                message = "Проверяем helper..."
            }
        }
    }

    func connect() async {
        await connect(antiLeakEnabled: false)
    }

    func connect(antiLeakEnabled: Bool) async {
        let command = antiLeakEnabled ? "up owner_pid=\(ProcessInfo.processInfo.processIdentifier)" : "up-no-antileak owner_pid=\(ProcessInfo.processInfo.processIdentifier)"
        await runCommand(command, busyState: .connecting, successMessage: "VPN подключен.")
    }

    func disconnect() async {
        await disconnect(releaseAntiLeak: true)
    }

    func disconnect(releaseAntiLeak: Bool) async {
        await runCommand(releaseAntiLeak ? "down" : "down-keep-antileak", busyState: .disconnecting, successMessage: "VPN отключен.")
    }

    func interruptWithDisconnect(releaseAntiLeak: Bool) async {
        status = status.withState(.disconnecting)
        do {
            let response = try await client.send(releaseAntiLeak ? "down" : "down-keep-antileak")
            if response.trimmingCharacters(in: .whitespacesAndNewlines) != "ok" {
                throw VEXHelperError.commandFailed(response)
            }
            message = "VPN отключен."
        } catch {
            message = VEXUserFacingText.status("Command failed: \(error.localizedDescription)")
        }
        await refreshStatus(quiet: true)
    }

    func detachOwnerWatchdog() async {
        do {
            _ = try await client.send("detach-owner")
        } catch {
            message = error.localizedDescription
        }
    }

    func diagnostics() async throws -> String {
        try await client.send("diagnostics")
    }

    func ensureHelperReady() async throws {
        try await installer.ensureReady(allowAdminInstall: true)
        installState = installer.installedState
    }

    private func runCommand(_ command: String, busyState: VpnConnectionState, successMessage: String) async {
        guard !isBusy else { return }
        isBusy = true
        status = status.withState(busyState)
        defer { isBusy = false }

        do {
            try await installer.ensureReady(allowAdminInstall: true)
            if isConnectCommand(command) {
                await client.silentDisconnect(releaseAntiLeak: false)
            }
            let response = try await sendCommandWithRetry(command)
            if response.trimmingCharacters(in: .whitespacesAndNewlines) != "ok" {
                throw VEXHelperError.commandFailed(response)
            }
            installState = installer.installedState
            message = successMessage
            await refreshStatus(quiet: true)
        } catch {
            message = VEXUserFacingText.status("Command failed: \(error.localizedDescription)")
            await refreshStatus(quiet: true)
        }
    }

    private func sendCommandWithRetry(_ command: String) async throws -> String {
        do {
            return try await client.send(command)
        } catch {
            guard isConnectCommand(command), error.isRetryableConnectFailure else {
                throw error
            }
            await client.silentDisconnect(releaseAntiLeak: false)
            return try await client.send(command)
        }
    }

    private func isConnectCommand(_ command: String) -> Bool {
        command.hasPrefix("up")
    }
}

struct VEXHelperClient {
    var socketPath = "/var/run/vex-helper.sock"

    func send(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try sendUnixSocketCommand(command, socketPath: socketPath)
        }.value
    }

    func sendStatus() async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await send("status")
            } catch {
                lastError = error
                if (error as? VEXHelperError)?.isStaleSocketFailure == true {
                    break
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
        }
        throw lastError ?? VEXHelperError.readFailed
    }

    func silentDisconnect(releaseAntiLeak: Bool) async {
        let command = releaseAntiLeak ? "down" : "down-keep-antileak"
        _ = try? await send(command)
    }
}

enum VEXHelperError: LocalizedError {
    case socketCreateFailed
    case connectFailed(String)
    case writeFailed
    case readFailed
    case invalidPath
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed:
            return "could not create Unix socket"
        case .connectFailed(let detail):
            return "could not connect to helper socket (\(detail))"
        case .writeFailed:
            return "could not write helper command"
        case .readFailed:
            return "could not read helper response"
        case .invalidPath:
            return "invalid helper socket path"
        case .commandFailed(let response):
            return response
        }
    }

    var isStaleSocketFailure: Bool {
        if case .connectFailed(let detail) = self {
            return detail.localizedCaseInsensitiveContains("connection refused")
        }
        return false
    }
}

private extension Error {
    var isRetryableConnectFailure: Bool {
        if let helperError = self as? VEXHelperError {
            switch helperError {
            case .connectFailed, .writeFailed, .readFailed:
                return true
            case .commandFailed(let response):
                let message = response.localizedLowercase
                return message.contains("could not connect to helper socket")
                    || message.contains("could not write helper command")
                    || message.contains("could not read helper response")
                    || message.contains("connection refused")
            default:
                return false
            }
        }
        let message = localizedDescription.localizedLowercase
        return message.contains("connection refused")
            || message.contains("could not connect to helper socket")
            || message.contains("could not write helper command")
            || message.contains("could not read helper response")
    }
}

func sendUnixSocketCommand(_ command: String, socketPath: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VEXHelperError.socketCreateFailed }
    defer { close(fd) }
    setSocketTimeout(fd, seconds: 5)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8.count < maxPathLength else { throw VEXHelperError.invalidPath }

    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        socketPath.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, maxPathLength)
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        throw VEXHelperError.connectFailed(String(cString: strerror(errno)))
    }

    let payload = command.hasSuffix("\n") ? command : "\(command)\n"
    let bytesWritten = payload.withCString { pointer in
        Darwin.write(fd, pointer, strlen(pointer))
    }
    guard bytesWritten == payload.utf8.count else { throw VEXHelperError.writeFailed }

    var response = [UInt8]()
    var byte: UInt8 = 0
    while response.count < 8192 {
        let bytesRead = Darwin.read(fd, &byte, 1)
        if bytesRead == 1 {
            response.append(byte)
            if byte == 10 {
                break
            }
            continue
        }
        if bytesRead == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        throw VEXHelperError.readFailed
    }

    guard !response.isEmpty else { throw VEXHelperError.readFailed }
    return String(decoding: response, as: UTF8.self)
}

private func setSocketTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rawPointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rawPointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rawPointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}

struct VpnStatus: Equatable {
    var state: VpnConnectionState
    var rxBytes: UInt64
    var txBytes: UInt64
    var latestHandshake: UInt64?
    var leakProtection: String
    var interfaceName: String?
    var endpoint: String?

    static let disconnected = VpnStatus(
        state: .disconnected,
        rxBytes: 0,
        txBytes: 0,
        latestHandshake: nil,
        leakProtection: "off",
        interfaceName: nil,
        endpoint: nil
    )

    init(helperResponse: String) {
        let values = helperResponse
            .split(whereSeparator: \.isNewline)
            .flatMap { line -> [(String, String)] in
                line.split(separator: " ").compactMap { part in
                    let pieces = part.split(separator: "=", maxSplits: 1)
                    guard pieces.count == 2 else { return nil }
                    return (String(pieces[0]), String(pieces[1]))
                }
            }
            .reduce(into: [String: String]()) { result, item in
                result[item.0] = item.1
            }

        let routeOk = values["route_ok"] == "true"
        let socketExists = values["socket_exists"] == "true"
        let operationInProgress = values["operation_in_progress"] == "true"
        let rx = UInt64(values["rx"] ?? "") ?? 0
        let tx = UInt64(values["tx"] ?? "") ?? 0
        let handshake = UInt64(values["latest_handshake"] ?? "").flatMap { $0 > 0 ? $0 : nil }

        let nextState: VpnConnectionState
        if operationInProgress {
            nextState = .connecting
        } else if routeOk || socketExists || rx > 0 || tx > 0 || handshake != nil {
            nextState = .connected
        } else {
            nextState = .disconnected
        }

        self.state = nextState
        self.rxBytes = rx
        self.txBytes = tx
        self.latestHandshake = handshake
        self.leakProtection = values["leak_protection"] ?? "off"
        self.interfaceName = values["iface"].flatMap { $0.isEmpty ? nil : $0 }
        self.endpoint = values["endpoint"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private init(
        state: VpnConnectionState,
        rxBytes: UInt64,
        txBytes: UInt64,
        latestHandshake: UInt64?,
        leakProtection: String,
        interfaceName: String?,
        endpoint: String?
    ) {
        self.state = state
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.latestHandshake = latestHandshake
        self.leakProtection = leakProtection
        self.interfaceName = interfaceName
        self.endpoint = endpoint
    }

    var handshakeText: String {
        guard let latestHandshake else { return "pending" }
        return Date(timeIntervalSince1970: TimeInterval(latestHandshake)).formatted(date: .omitted, time: .shortened)
    }

    func withState(_ state: VpnConnectionState) -> VpnStatus {
        var copy = self
        copy.state = state
        return copy
    }
}

enum VpnConnectionState: String, Equatable {
    case connected
    case connecting
    case disconnecting
    case disconnected

    var title: String {
        switch self {
        case .connected:
            return "Protected"
        case .connecting:
            return "Connecting"
        case .disconnecting:
            return "Disconnecting"
        case .disconnected:
            return "Disconnected"
        }
    }

    var symbolName: String {
        switch self {
        case .connected:
            return "checkmark.shield.fill"
        case .connecting:
            return "hourglass"
        case .disconnecting:
            return "hourglass"
        case .disconnected:
            return "xmark.shield"
        }
    }

    var color: Color {
        switch self {
        case .connected:
            return .green
        case .connecting, .disconnecting:
            return .yellow
        case .disconnected:
            return .secondary
        }
    }
}
