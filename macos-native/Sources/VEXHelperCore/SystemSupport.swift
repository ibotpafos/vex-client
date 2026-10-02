import Darwin
import Foundation

private final class LockedCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) {
        lock.withLock { stdout = data }
    }

    func setStderr(_ data: Data) {
        lock.withLock { stderr = data }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.withLock { (stdout, stderr) }
    }
}

public final class LocalFileSystem: HelperFileSystem, @unchecked Sendable {
    private let manager = FileManager.default
    private let syncDescriptor: (Int32) -> Int32

    public init() { syncDescriptor = Darwin.fsync }

    // Internal fault-injection seam; production construction always uses fsync.
    init(syncDescriptor: @escaping (Int32) -> Int32) {
        self.syncDescriptor = syncDescriptor
    }

    public func createDirectory(at path: String) throws {
        try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func fileExists(at path: String) -> Bool {
        manager.fileExists(atPath: path)
    }

    public func pathPresence(at path: String) -> HelperPathPresence {
        var metadata = stat()
        if lstat(path, &metadata) == 0 { return .present }
        guard errno == ENOENT else { return .unknown }
        // A dangling journal symlink is present (lstat above). A missing leaf
        // under an inaccessible, non-directory or dangling parent is unknown.
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path else { return .unknown }
        if lstat(parent, &metadata) == 0 {
            return (metadata.st_mode & S_IFMT) == S_IFDIR ? .absent : .unknown
        }
        guard errno == ENOENT else { return .unknown }
        return pathPresence(at: parent) == .absent ? .absent : .unknown
    }

    public func fileSize(at path: String) -> UInt64? {
        (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    public func modificationDate(at path: String) -> Date? {
        try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    public func readText(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    public func writeTextAtomically(_ text: String, to path: String, mode: Int) throws {
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent().path
        try createDirectory(at: parent)
        // Pin the parent inode before creating/renaming the temporary file.
        let directoryFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw HelperError.io("could not open atomic destination directory")
        }
        defer { _ = Darwin.close(directoryFD) }
        let tempName = ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(directoryFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard descriptor >= 0 else {
            throw HelperError.io("could not create atomic temp file for \(path): \(String(cString: strerror(errno)))")
        }
        var descriptorIsOpen = true
        do {
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw HelperError.io("could not write atomic temp file for \(path): \(String(cString: strerror(errno)))")
                }
                offset += count
            }
            guard Darwin.fchmod(descriptor, mode_t(mode)) == 0 else {
                throw HelperError.io("could not chmod atomic temp file for \(path)")
            }
            guard synchronize(descriptor) == 0 else {
                throw HelperError.io("could not fsync atomic temp file for \(path)")
            }
            // close() failure must not cause a second close of a reused fd.
            descriptorIsOpen = false
            guard Darwin.close(descriptor) == 0 else {
                throw HelperError.io("could not close atomic temp file for \(path)")
            }
            guard Darwin.renameat(directoryFD, tempName, directoryFD, destination.lastPathComponent) == 0 else {
                throw HelperError.io("could not atomically replace \(path): \(String(cString: strerror(errno)))")
            }
            guard synchronize(directoryFD) == 0 else {
                // The rename may have happened: preserve destination evidence,
                // report failure, and never authorize a subsequent VPN mutation.
                throw HelperError.io("could not fsync atomic destination directory")
            }
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            _ = Darwin.unlinkat(directoryFD, tempName, 0)
            throw error
        }
    }

    private func synchronize(_ descriptor: Int32) -> Int32 {
        var result: Int32
        repeat { result = syncDescriptor(descriptor) } while result < 0 && errno == EINTR
        return result
    }

    public func removeItem(at path: String) throws {
        guard manager.fileExists(atPath: path) else { return }
        try manager.removeItem(atPath: path)
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ spec: CommandSpec) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.program)
        process.arguments = spec.arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        let readGroup = DispatchGroup()
        let output = LockedCommandOutput()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            output.setStdout(data)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            output.setStderr(data)
            readGroup.leave()
        }
        var timedOut = false
        if termination.wait(timeout: .now() + spec.timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }
        if readGroup.wait(timeout: .now() + 1) == .timedOut {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 1)
        }
        let captured = output.snapshot()
        return CommandResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: String(decoding: captured.stdout, as: UTF8.self),
            stderr: String(decoding: captured.stderr, as: UTF8.self)
        )
    }
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func processIdentity(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let byteCount = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return [
            "pid=\(pid)",
            "start_sec=\(info.pbi_start_tvsec)",
            "start_usec=\(info.pbi_start_tvusec)",
            "uid=\(info.pbi_uid)",
        ].joined(separator: ";")
    }
}

public final class SystemPFFirewallController: PFFirewallControlling, @unchecked Sendable {
    private let runner: CommandRunning
    private let fileSystem: HelperFileSystem
    private let paths: HelperPathsLayout
    private let logger: HelperLogging

    public init(
        runner: CommandRunning,
        fileSystem: HelperFileSystem,
        paths: HelperPathsLayout = .init(),
        logger: HelperLogging = StderrLogger()
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.paths = paths
        self.logger = logger
    }

    public func antileakIsActive() -> Bool {
        fileSystem.fileExists(at: paths.antileakStatePath)
            || fileSystem.fileExists(at: paths.legacyAntileakStatePath)
            || (fileSystem.fileSize(at: paths.antileakAnchorPath) ?? 0) > 0
    }

    public func enable(endpoint: String, interfaceName: String) throws {
        try fileSystem.writeTextAtomically("", to: paths.antileakAnchorPath, mode: 0o644)
        try ensureAnchorRegistered()
        try fileSystem.writeTextAtomically(
            "status=pending\nendpoint=\(endpoint)\niface=\(interfaceName)\n",
            to: paths.antileakStatePath,
            mode: 0o600
        )
        try fileSystem.writeTextAtomically(buildRules(endpoint: endpoint, interfaceName: interfaceName), to: paths.antileakAnchorPath, mode: 0o644)

        let load = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-f", paths.antileakAnchorPath]))
        guard load.succeeded else {
            _ = try? disable()
            throw HelperError.commandFailed("pfctl -a com.vexguard.antileak -f failed with status \(load.status)")
        }

        let enable = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-E"]))
        guard enable.succeeded else {
            _ = try? disable()
            throw HelperError.commandFailed("pfctl -E failed with status \(enable.status)")
        }

        do {
            try fileSystem.writeTextAtomically(
                "status=active\nendpoint=\(endpoint)\niface=\(interfaceName)\n",
                to: paths.antileakStatePath,
                mode: 0o600
            )
        } catch {
            _ = try? disable()
            throw error
        }
    }

    /// Fail-closed replacement for a *currently armed* VEX anchor.  This is
    /// intentionally separate from `enable`: it never toggles PF, flushes an
    /// anchor, or reloads the global PF configuration.
    // TODO: A normal-profile handover must add an operation lock and durable
    // journal around this primitive before invoking it. This method alone is
    // not live-PF clearance.
    public func updateWhileArmed(endpoint: String, interfaceName: String) throws {
        let candidateRules = try checkedRules(endpoint: endpoint, interfaceName: interfaceName)
        let previous = try captureArmedAnchor()

        do {
            // The atomic write leaves either the complete old rules or the
            // complete candidate rules at the path supplied to pfctl.
            try fileSystem.writeTextAtomically(candidateRules, to: paths.antileakAnchorPath, mode: 0o644)
            let load = try runner.run(CommandSpec(
                program: "/sbin/pfctl",
                arguments: ["-a", "com.vexguard.antileak", "-f", paths.antileakAnchorPath]
            ))
            guard load.succeeded else {
                throw HelperError.commandFailed("pfctl anti-leak anchor replacement failed with status \(load.status)")
            }
            try verifyArmedAnchor(expectedRules: candidateRules)
            try fileSystem.writeTextAtomically(
                "status=active\nendpoint=\(endpoint)\niface=\(interfaceName)\n",
                to: paths.antileakStatePath,
                mode: 0o600
            )
            // A legacy marker is not an authority for this update, but a
            // stale marker is removed only after the replacement is proven.
            try fileSystem.removeItem(at: paths.legacyAntileakStatePath)
            logger.info("antileak", "pf armed anchor rules replaced")
        } catch {
            let rollbackFailure = restoreArmedAnchor(previous)
            if let rollbackFailure {
                throw HelperError.commandFailed("PF armed-rule replacement failed: \(error.localizedDescription); rollback failed: \(rollbackFailure)")
            }
            throw error
        }
    }

    private struct ArmedAnchorSnapshot {
        let anchorRules: String
        let state: String?
        let legacyState: String?
    }

    private func captureArmedAnchor() throws -> ArmedAnchorSnapshot {
        try verifyPersistentAnchorRegistration()
        guard fileSystem.fileExists(at: paths.antileakAnchorPath),
              let size = fileSystem.fileSize(at: paths.antileakAnchorPath), size > 0 else {
            throw HelperError.commandFailed("PF anti-leak anchor file is not armed")
        }
        let anchorRules = try fileSystem.readText(at: paths.antileakAnchorPath)
        let state = try optionalText(at: paths.antileakStatePath)
        guard let state, let armed = armedState(from: state), armed.status == "active" else {
            throw HelperError.commandFailed("PF anti-leak state is not armed")
        }
        let expectedRules = try checkedRules(endpoint: armed.endpoint, interfaceName: armed.interfaceName)
        guard anchorRules == expectedRules else {
            throw HelperError.commandFailed("PF anti-leak anchor does not match its armed state")
        }
        try verifyArmedAnchor(expectedRules: expectedRules)
        return ArmedAnchorSnapshot(
            anchorRules: anchorRules,
            state: state,
            legacyState: try optionalText(at: paths.legacyAntileakStatePath)
        )
    }

    private func optionalText(at path: String) throws -> String? {
        guard fileSystem.fileExists(at: path) else { return nil }
        return try fileSystem.readText(at: path)
    }

    private func verifyPersistentAnchorRegistration() throws {
        let declaration = "anchor \"com.vexguard.antileak\""
        let loadDeclaration = "load anchor \"com.vexguard.antileak\" from \"\(paths.antileakAnchorPath)\""
        let configuration = try fileSystem.readText(at: paths.pfConfigPath)
        let effectiveLines = configuration.split(whereSeparator: \.isNewline).map { line -> String in
            String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
        }
        guard effectiveLines.contains(declaration), effectiveLines.contains(loadDeclaration) else {
            throw HelperError.commandFailed("PF anti-leak anchor is not persistently registered")
        }
    }

    private func verifyArmedAnchor(expectedRules: String? = nil) throws {
        guard try pfIsEnabled() else {
            throw HelperError.commandFailed("PF is disabled; refusing anti-leak rule replacement")
        }
        let runtime = try runner.run(CommandSpec(
            program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-sr"]
        ))
        guard runtime.succeeded, !runtime.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelperError.commandFailed("PF anti-leak anchor has no loaded rules")
        }
        if let expectedRules {
            // `pfctl -sr` intentionally does not print global `set` options.
            // Every printed rule must instead be one of this anchor's expected
            // non-global rules; this rejects an unrelated physical-interface
            // pass as well as a broad pass inserted before the final block.
            let expectedRuntimeLines = normalizedArmedRules(expectedRules, excludingSourceOptions: true)
            let runtimeLines = normalizedArmedRules(runtime.stdout)
            // Exact ordered rule coverage binds interface, AF, endpoint and
            // ports too. Missing/extra/reordered or non-default flags fail
            // closed; a fragment/subset match is not ownership evidence.
            guard !runtimeLines.isEmpty, runtimeLines == expectedRuntimeLines else {
                throw HelperError.commandFailed("PF anti-leak anchor does not match expected armed rules")
            }
        }
    }

    private func normalizedArmedRules(_ text: String, excludingSourceOptions: Bool = false) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { return nil }
            if excludingSourceOptions, tokens.first == "set" { return nil }
            if tokens.first == "pass" {
                // PF prints its default state/initial-SYN flags even when the
                // input omits them. Normalize only these exact safe defaults.
                if tokens.suffix(2).elementsEqual(["keep", "state"]) { tokens.removeLast(2) }
                if tokens.suffix(2).elementsEqual(["flags", "S/SA"]),
                   !tokens.contains("udp") { tokens.removeLast(2) }
            }
            if let port = tokens.firstIndex(of: "port"), tokens.indices.contains(port + 2), tokens[port + 1] == "=" {
                if tokens[port + 2] == "https" { tokens[port + 2] = "443" }
                if tokens[port + 2] == "ssh" { tokens[port + 2] = "22" }
            }
            return tokens.joined(separator: " ")
        }
    }

    private func restoreArmedAnchor(_ snapshot: ArmedAnchorSnapshot) -> String? {
        var failures: [String] = []
        do {
            try fileSystem.writeTextAtomically(snapshot.anchorRules, to: paths.antileakAnchorPath, mode: 0o644)
            let reload = try runner.run(CommandSpec(
                program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-f", paths.antileakAnchorPath]
            ))
            if !reload.succeeded { failures.append("pfctl anchor rollback status \(reload.status)") }
            else { try verifyArmedAnchor(expectedRules: snapshot.anchorRules) }
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try restoreOptionalText(snapshot.state, at: paths.antileakStatePath, mode: 0o600)
            try restoreOptionalText(snapshot.legacyState, at: paths.legacyAntileakStatePath, mode: 0o600)
        } catch {
            failures.append(error.localizedDescription)
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func restoreOptionalText(_ text: String?, at path: String, mode: Int) throws {
        if let text {
            try fileSystem.writeTextAtomically(text, to: path, mode: mode)
        } else {
            try fileSystem.removeItem(at: path)
        }
    }

    private func ensureAnchorRegistered() throws {
        let anchorDeclaration = "anchor \"com.vexguard.antileak\""
        let loadDeclaration = "load anchor \"com.vexguard.antileak\" from \"\(paths.antileakAnchorPath)\""
        let current = try fileSystem.readText(at: paths.pfConfigPath)
        guard !current.contains(anchorDeclaration) || !current.contains(loadDeclaration) else {
            return
        }
        var updated = current
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated.append("\n")
        }
        updated.append(
            "\n# VEX VPN anti-leak kill switch\n\(anchorDeclaration)\n\(loadDeclaration)\n"
        )
        try fileSystem.writeTextAtomically(updated, to: paths.pfConfigPath, mode: 0o644)
        let reload = try runner.run(CommandSpec(
            program: "/sbin/pfctl",
            arguments: ["-f", paths.pfConfigPath]
        ))
        guard reload.succeeded else {
            try? fileSystem.writeTextAtomically(current, to: paths.pfConfigPath, mode: 0o644)
            _ = try? runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-f", paths.pfConfigPath]))
            throw HelperError.commandFailed("pfctl -f \(paths.pfConfigPath) failed with status \(reload.status)")
        }
    }

    public func disable() throws {
        let flush = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-F", "all"]))
        if !flush.succeeded {
            if try !pfIsDisabled() {
                throw HelperError.commandFailed("pfctl -a com.vexguard.antileak -F all failed with status \(flush.status)")
            }
        } else {
            try verifyRuntimeAnchorEmpty()
        }
        do {
            try fileSystem.writeTextAtomically("", to: paths.antileakAnchorPath, mode: 0o644)
            try fileSystem.removeItem(at: paths.antileakStatePath)
            try fileSystem.removeItem(at: paths.legacyAntileakStatePath)
        } catch {
            throw HelperError.pfPersistenceAfterRuntimeClear(error.localizedDescription)
        }
        logger.info("antileak", "pf anchor cleared")
    }

    private func verifyRuntimeAnchorEmpty() throws {
        let result = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-sr"]))
        if result.succeeded, result.stdout.allSatisfy(\.isWhitespace) {
            return
        }
        if try pfIsDisabled() {
            return
        }
        throw HelperError.commandFailed("pf anchor com.vexguard.antileak still contains runtime rules after flush")
    }

    private func pfIsEnabled() throws -> Bool {
        let result = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-s", "info"]))
        guard result.succeeded else {
            throw HelperError.commandFailed("pfctl -s info failed with status \(result.status)")
        }
        let statuses = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("Status:") }
        guard statuses.count == 1 else { throw HelperError.commandFailed("PF enabled status is unrecognized") }
        if statuses[0] == "Status: Enabled" || statuses[0].hasPrefix("Status: Enabled for ") { return true }
        if statuses[0] == "Status: Disabled" || statuses[0].hasPrefix("Status: Disabled for ") { return false }
        throw HelperError.commandFailed("PF enabled status is unrecognized")
    }

    // Retain the pre-existing explicit-disabled contract for normal teardown.
    private func pfIsDisabled() throws -> Bool {
        let result = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-s", "info"]))
        guard result.succeeded else { throw HelperError.commandFailed("pfctl -s info failed with status \(result.status)") }
        return result.stdout.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Status: Disabled" }
    }

    private struct PFEndpoint {
        let host: String
        let port: UInt16?
        let addressFamily: String
    }

    private func checkedRules(endpoint: String, interfaceName: String) throws -> String {
        guard validInterfaceName(interfaceName), let parsedEndpoint = pfEndpoint(from: endpoint),
              parsedEndpoint.port != nil else {
            throw HelperError.protocolViolation("invalid PF anti-leak endpoint or interface")
        }
        return buildRules(endpoint: parsedEndpoint, interfaceName: interfaceName)
    }

    private func buildRules(endpoint: String, interfaceName: String) -> String {
        guard let parsedEndpoint = pfEndpoint(from: endpoint) else {
            // Existing enable behavior deliberately keeps its compatibility
            // path. New armed replacement calls checkedRules above.
            return buildRules(endpoint: nil, interfaceName: interfaceName)
        }
        return buildRules(endpoint: parsedEndpoint, interfaceName: interfaceName)
    }

    private func buildRules(endpoint: PFEndpoint?, interfaceName: String) -> String {
        var rules = "set block-policy drop\npass quick on lo0 all\npass out quick on \(interfaceName) all\n"
        if let endpoint {
            if let port = endpoint.port {
                rules += "pass out quick \(endpoint.addressFamily) proto udp from any to \(endpoint.host) port = \(port) keep state\n"
            }
            rules += "pass out quick \(endpoint.addressFamily) proto tcp from any to \(endpoint.host) port = 443 keep state\n"
            rules += "pass out quick \(endpoint.addressFamily) proto tcp from any to \(endpoint.host) port = 22 keep state\n"
        }
        rules += "block drop out all\n"
        return rules
    }

    private func validInterfaceName(_ value: String) -> Bool {
        guard value.hasPrefix("utun"), value.utf8.count > 4, value.utf8.count <= 15 else { return false }
        return value.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) }
    }

    private struct ArmedState { let status: String; let endpoint: String; let interfaceName: String }
    private func armedState(from text: String) -> ArmedState? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, values[pair[0]] == nil else { return nil }
            values[pair[0]] = pair[1]
        }
        guard let status = values["status"], let endpoint = values["endpoint"], let interfaceName = values["iface"] else { return nil }
        return ArmedState(status: status, endpoint: endpoint, interfaceName: interfaceName)
    }

    private func pfEndpoint(from endpoint: String) -> PFEndpoint? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "[" {
            guard let closingBracket = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            let suffix = value[value.index(after: closingBracket)...]
            let port: UInt16?
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":", let parsedPort = validPort(String(suffix.dropFirst())) else { return nil }
                port = parsedPort
            }
            guard validIPv6Host(host) else { return nil }
            return PFEndpoint(host: host, port: port, addressFamily: "inet6")
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let host: String
        let port: UInt16?
        switch parts.count {
        case 1:
            host = String(parts[0])
            port = nil
        case 2:
            host = String(parts[0])
            guard let parsedPort = validPort(String(parts[1])) else { return nil }
            port = parsedPort
        default:
            return nil
        }
        guard validIPv4OrHostname(host) else { return nil }
        return PFEndpoint(host: host, port: port, addressFamily: "inet")
    }

    private func validPort(_ value: String) -> UInt16? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = UInt16(value), port > 0 else {
            return nil
        }
        return port
    }

    private func validIPv4OrHostname(_ host: String) -> Bool {
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 {
            return true
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return host.utf8.count <= 253 && labels.allSatisfy(validHostnameLabel)
    }

    private func validIPv6Host(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }

    private func validHostnameLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63,
              let first = label.utf8.first, let last = label.utf8.last,
              first != 45, last != 45 else {
            return false
        }
        return label.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
        }
    }
}

public final class SystemTunnelController: TunnelControlling, @unchecked Sendable {
    private let fileSystem: HelperFileSystem
    private let paths: HelperPathsLayout
    private let runner: CommandRunning
    private let firewall: PFFirewallControlling

    public init(
        fileSystem: HelperFileSystem,
        paths: HelperPathsLayout = .init(),
        runner: CommandRunning,
        firewall: PFFirewallControlling
    ) {
        self.fileSystem = fileSystem
        self.paths = paths
        self.runner = runner
        self.firewall = firewall
    }

    /// Protected replacement foundation. Deliberately not exposed by the
    /// helper socket or normal app coordinator until their owner/intent and
    /// completed-handshake gates are verified on an isolated Mac.
    // TODO: Bind the authenticated helper RPC and normal coordinator to this
    // operation and explicit journal recovery, with process/intent and fresh
    // handshake validation. Runtime now isolates pending journals; that guard
    // alone does not complete recovery or authorize live coordinator cutover.
    public func replacePreservingAntiLeak(
        currentSession: HelperSession?, ownerPID: Int32, expectedConfigSHA256: String
    ) throws -> HelperSession {
        let store = HelperStateStore(fileSystem: fileSystem, paths: paths)
        return try store.withOperationLock(staleAfter: 120) {
            try store.requireNoPendingReplacement()
            guard ownerPID > 1, let source = currentSession,
                  source.ownerPID == ownerPID, source.antiLeakArmed,
                  source.socketExists, validReplacementInterface(source.interfaceName),
                  firewall.antileakIsActive() else {
                throw HelperError.ownerVerificationFailed("protected replacement requires an owned armed source")
            }
            let sourceConfig = try fileSystem.readText(at: paths.activeConfigPath)
            guard ProtectedReplacementJournal.digest(sourceConfig) == expectedConfigSHA256,
                  try endpoint(fromConfigAt: paths.activeConfigPath) == source.endpoint,
                  try resolvedInterfaceName(logicalInterface: "active") == source.interfaceName,
                  fileSystem.fileExists(at: paths.runtimeSocketPath(for: source.interfaceName))
                    || fileSystem.fileExists(at: paths.amneziaSocketPath(for: source.interfaceName)) else {
                throw HelperError.ownerVerificationFailed("protected replacement source changed")
            }
            try AwgConfigAdmission.validate(sourceConfig)
            let candidate = try sanitizedConfig(from: fileSystem.readText(at: resolvedConfigPath()))
            try AwgConfigAdmission.validate(candidate)
            guard sourceConfig != candidate, candidate.utf8.count <= 262_144,
                  sourceConfig.utf8.count <= 262_144 else {
                throw HelperError.protocolViolation("protected replacement candidate is unchanged or oversized")
            }
            let dns = try fileSystem.readText(at: paths.dnsStatePath)
            guard !dns.isEmpty, dns.utf8.count <= 262_144 else {
                throw HelperError.missingTunnelMetadata("protected replacement requires a DNS recovery baseline")
            }
            let ownerSnapshot = try protectedOwnerSnapshot(ownerPID: ownerPID)
            var journal = ProtectedReplacementJournal(
                ownerPID: ownerPID, sourceSession: source.payload,
                sourceConfig: sourceConfig, sourceSHA256: expectedConfigSHA256,
                candidateConfig: candidate, candidateSHA256: ProtectedReplacementJournal.digest(candidate),
                dnsBaseline: dns, ownerSession: ownerSnapshot
            )
            // Atomic source journal and readback precede every PF/quick mutation.
            // TODO: Validate OS-crash/power-loss durability on an isolated Mac;
            // fsync plus an offline memory-port test is not that acceptance gate.
            try persistReplacementJournal(journal)
            var sourceMayHaveStopped = false
            do {
                try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
                // This validates and reloads only the existing armed anchor;
                // unlike generic bringUp/bringDown it never disables PF.
                try firewall.updateWhileArmed(endpoint: source.endpoint, interfaceName: source.interfaceName)
                journal.phase = "replacing"
                try persistReplacementJournal(journal)
                try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
                sourceMayHaveStopped = true
                try checkedReplacementQuick("down")
                try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
                try fileSystem.writeTextAtomically(candidate, to: paths.activeConfigPath, mode: 0o600)
                let candidateEndpoint = try endpoint(fromConfigAt: paths.activeConfigPath)
                try firewall.updateWhileArmed(endpoint: candidateEndpoint, interfaceName: source.interfaceName)
                try checkedReplacementQuick("up")
                let result = try finishProtectedSession(ownerPID: ownerPID, store: store)
                try requireReplacementState(journal, allowedHashes: [journal.candidateSHA256])
                journal.phase = "committed"
                try persistReplacementJournal(journal)
                try fileSystem.removeItem(at: replacementJournalPath)
                return result
            } catch {
                // Never print an underlying command error: awg config/output
                // can carry key material. The journal remains on failed undo.
                if sourceMayHaveStopped {
                    do { _ = try restoreProtectedSource(journal, store: store) }
                    catch { throw HelperError.commandFailed("protected replacement failed; source recovery remains pending") }
                    throw HelperError.commandFailed("protected replacement failed; source restored with protection armed")
                }
                throw HelperError.commandFailed("protected replacement admission failed; recovery journal retained")
            }
        }
    }

    /// Explicit recovery only, not called from startup or the live coordinator.
    /// The future authenticated RPC must revalidate process identity and intent.
    public func recoverProtectedReplacement(ownerPID: Int32) throws -> HelperSession? {
        let store = HelperStateStore(fileSystem: fileSystem, paths: paths)
        return try store.withOperationLock(staleAfter: 120) {
            switch fileSystem.pathPresence(at: replacementJournalPath) {
            case .absent: return nil
            case .unknown: throw HelperError.replacementRecoveryPending
            case .present: break
            }
            let journal = try ProtectedReplacementJournal.decode(fileSystem.readText(at: replacementJournalPath))
            guard journal.ownerPID == ownerPID else {
                throw HelperError.ownerVerificationFailed("protected recovery owner changed")
            }
            try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256, journal.candidateSHA256])
            if journal.phase == "prepared" {
                // Admission/journal failure occurred before quick down. A stale
                // prepared record must not tear down a still-running source.
                try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
                guard let source = HelperSession(payload: journal.sourceSession),
                      try resolvedInterfaceName(logicalInterface: "active") == source.interfaceName else {
                    throw HelperError.ownerVerificationFailed("protected recovery source changed")
                }
                let result = try finishProtectedSession(ownerPID: ownerPID, store: store)
                try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
                try fileSystem.removeItem(at: replacementJournalPath)
                return result
            }
            if journal.phase == "committed",
               ProtectedReplacementJournal.digest(try fileSystem.readText(at: paths.activeConfigPath)) == journal.candidateSHA256,
               let persisted = store.loadSession(), persisted.ownerPID == ownerPID {
                let result = try finishProtectedSession(ownerPID: ownerPID, store: store)
                try requireReplacementState(journal, allowedHashes: [journal.candidateSHA256])
                try fileSystem.removeItem(at: replacementJournalPath)
                return result
            }
            return try restoreProtectedSource(journal, store: store)
        }
    }

    private var replacementJournalPath: String { paths.helperDirectory + "/replacement-journal.state" }

    private func validReplacementInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") && !name.dropFirst(4).isEmpty
            && name.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) }
    }

    private func persistReplacementJournal(_ journal: ProtectedReplacementJournal) throws {
        try fileSystem.writeTextAtomically(try journal.encoded(), to: replacementJournalPath, mode: 0o600)
        let reread = try ProtectedReplacementJournal.decode(fileSystem.readText(at: replacementJournalPath))
        guard try reread.encoded() == journal.encoded() else {
            throw HelperError.io("protected replacement journal verification failed")
        }
    }

    private func protectedOwnerSnapshot(ownerPID: Int32) throws -> String? {
        guard fileSystem.fileExists(at: paths.ownerSessionPath) else { return nil }
        let text = try fileSystem.readText(at: paths.ownerSessionPath)
        guard text.utf8.count <= 16_384, let owner = OwnerSession(payload: text),
              owner.pid == ownerPID, !owner.token.isEmpty, !owner.identity.isEmpty,
              text == owner.payload else {
            throw HelperError.ownerVerificationFailed("protected replacement owner changed")
        }
        return text
    }

    private func requireReplacementState(_ journal: ProtectedReplacementJournal, allowedHashes: Set<String>) throws {
        let saved = try ProtectedReplacementJournal.decode(fileSystem.readText(at: replacementJournalPath))
        guard saved.transactionID == journal.transactionID,
              saved.phase == journal.phase,
              saved.ownerPID == journal.ownerPID,
              saved.ownerSession == journal.ownerSession,
              saved.sourceSession == journal.sourceSession,
              saved.dnsBaseline == journal.dnsBaseline,
              saved.sourceSHA256 == journal.sourceSHA256,
              saved.candidateSHA256 == journal.candidateSHA256,
              allowedHashes.contains(ProtectedReplacementJournal.digest(try fileSystem.readText(at: paths.activeConfigPath))),
              try fileSystem.readText(at: paths.dnsStatePath) == journal.dnsBaseline,
              firewall.antileakIsActive() else {
            throw HelperError.ownerVerificationFailed("protected replacement state changed; recovery retained")
        }
        guard try protectedOwnerSnapshot(ownerPID: journal.ownerPID) == journal.ownerSession else {
            throw HelperError.ownerVerificationFailed("protected replacement owner identity or intent changed")
        }
    }

    private func checkedReplacementQuick(_ action: String) throws {
        let result = try runQuick(action, configPath: paths.activeConfigPath)
        guard result.succeeded else {
            throw HelperError.commandFailed("protected tunnel operation failed with status \(result.status)")
        }
    }

    private func finishProtectedSession(ownerPID: Int32, store: HelperStateStore) throws -> HelperSession {
        let interface = try resolvedInterfaceName(logicalInterface: "active")
        guard validReplacementInterface(interface) else {
            throw HelperError.missingTunnelMetadata("invalid protected replacement interface")
        }
        let endpoint = try endpoint(fromConfigAt: paths.activeConfigPath)
        try firewall.updateWhileArmed(endpoint: endpoint, interfaceName: interface)
        let base = HelperSession(interfaceName: interface, endpoint: endpoint, ownerPID: ownerPID,
                                 antiLeakArmed: true, ipv6RouteExpected: configHasIPv6DefaultRoute(paths.activeConfigPath))
        guard let result = try refreshedSession(currentSession: base), result.socketExists,
              result.antiLeakArmed, result.dnsHealthy,
              result.routeInterface == interface,
              !result.ipv6RouteExpected || result.ipv6RouteInterface == interface else {
            throw HelperError.commandFailed("protected replacement runtime did not become ready")
        }
        // This is helper readiness, NOT a fresh signed-profile handshake proof.
        try store.persistSession(result)
        return result
    }

    private func restoreProtectedSource(_ input: ProtectedReplacementJournal, store: HelperStateStore) throws -> HelperSession {
        var journal = input
        try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256, journal.candidateSHA256])
        journal.phase = "rolling-back"
        try persistReplacementJournal(journal)
        // No global daemon-kill fallback: failure keeps PF and the source journal.
        try checkedReplacementQuick("down")
        try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256, journal.candidateSHA256])
        try fileSystem.writeTextAtomically(journal.sourceConfig, to: paths.activeConfigPath, mode: 0o600)
        guard let source = HelperSession(payload: journal.sourceSession), validReplacementInterface(source.interfaceName) else {
            throw HelperError.protocolViolation("protected source session is invalid")
        }
        try firewall.updateWhileArmed(endpoint: source.endpoint, interfaceName: source.interfaceName)
        try checkedReplacementQuick("up")
        let result = try finishProtectedSession(ownerPID: journal.ownerPID, store: store)
        try requireReplacementState(journal, allowedHashes: [journal.sourceSHA256])
        try fileSystem.removeItem(at: replacementJournalPath)
        return result
    }

    public func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession {
        // Admission is read-only and precedes even prior-session cleanup.
        let sanitized: String
        do {
            let sourceConfigPath = try resolvedConfigPath()
            sanitized = try sanitizedConfig(from: fileSystem.readText(at: sourceConfigPath))
            try AwgConfigAdmission.validate(sanitized)
        } catch {
            throw HelperError.protocolViolation("VPN_CONFIG_INVALID: next profile admission failed")
        }
        if currentSession != nil || hasManagedState() || firewall.antileakIsActive() {
            try bringDown(currentSession: currentSession)
        }

        try captureDNSBaseline()
        do {
            try fileSystem.writeTextAtomically(sanitized, to: paths.activeConfigPath, mode: 0o600)
        } catch {
            try? fileSystem.removeItem(at: paths.dnsStatePath)
            throw error
        }
        let configPath = paths.activeConfigPath
        let logicalInterface = URL(fileURLWithPath: configPath).deletingPathExtension().lastPathComponent
        guard !logicalInterface.isEmpty else {
            throw HelperError.missingTunnelMetadata("could not derive tunnel name from config path")
        }

        let up = try runQuick("up", configPath: configPath)
        guard up.succeeded else {
            let rollback = try? runQuick("down", configPath: configPath)
            let dnsRestored = (try? restoreDNSBaseline()) != nil
            if rollback?.succeeded == true, dnsRestored {
                clearRecoveryArtifacts()
            }
            throw HelperError.commandFailed("awg-quick up failed with status \(up.status): \(up.stderr)")
        }
        var interfaceName: String?
        do {
            interfaceName = try resolvedInterfaceName(logicalInterface: logicalInterface)
            let endpoint = try endpoint(fromConfigAt: configPath)
        let base = HelperSession(
            interfaceName: interfaceName!,
            endpoint: endpoint,
            ownerPID: ownerPID,
            antiLeakArmed: false
        )

        if armAntiLeak {
            try firewall.enable(endpoint: endpoint, interfaceName: interfaceName!)
        }

        return try refreshedSession(currentSession: HelperSession(
            interfaceName: interfaceName!,
            endpoint: endpoint,
            ownerPID: ownerPID,
            antiLeakArmed: armAntiLeak,
            ipv6RouteExpected: configHasIPv6DefaultRoute(configPath)
        )) ?? base
        } catch {
            let rollback = try? runQuick("down", configPath: configPath)
            var cleanupSucceeded = rollback?.succeeded == true
            if !cleanupSucceeded, interfaceName != nil {
                cleanupSucceeded = (try? fallbackInterfaceCleanup(interfaceName)) != nil
            }
            let dnsRestored = (try? restoreDNSBaseline()) != nil
            if cleanupSucceeded, dnsRestored {
                clearRecoveryArtifacts()
            }
            throw error
        }
    }

    public func bringDown(currentSession: HelperSession?) throws {
        var persistenceError: Error?
        if currentSession?.antiLeakArmed == true || firewall.antileakIsActive() {
            do {
                try firewall.disable()
            } catch let error as HelperError {
                guard case .pfPersistenceAfterRuntimeClear = error else { throw error }
                persistenceError = error
            }
        }

        let logicalInterface = "active"
        let namePath = paths.amneziaNamePath(for: logicalInterface)
        let activeConfigExists = fileSystem.fileExists(at: paths.activeConfigPath)
        let runtimeNameExists = fileSystem.fileExists(at: namePath)
        if currentSession == nil, !activeConfigExists, !runtimeNameExists {
            if let persistenceError { throw persistenceError }
            return
        }
        if !activeConfigExists {
            let fallbackName = currentSession?.interfaceName
                ?? (try? resolvedInterfaceName(logicalInterface: logicalInterface))
            try fallbackInterfaceCleanup(fallbackName)
            try restoreDNSBaseline()
            try? fileSystem.removeItem(at: namePath)
            try? fileSystem.removeItem(at: paths.dnsStatePath)
            if let persistenceError { throw persistenceError }
            return
        }
        let configPath = fileSystem.fileExists(at: paths.activeConfigPath)
            ? paths.activeConfigPath
            : try resolvedConfigPath()
        let down = try runQuick("down", configPath: configPath)
        var fallbackSucceeded = false
        if !down.succeeded {
            let logicalInterface = URL(fileURLWithPath: configPath).deletingPathExtension().lastPathComponent
            let fallbackName = currentSession?.interfaceName
                ?? (try? resolvedInterfaceName(logicalInterface: logicalInterface))
            if let fallbackName {
                try fallbackInterfaceCleanup(fallbackName)
                fallbackSucceeded = true
            } else if !runtimeNameExists {
                // awg-quick writes active.name immediately after creating the
                // interface. No name means the crash happened before add_if.
                fallbackSucceeded = true
            }
        }
        let tunnelCleaned = down.succeeded || fallbackSucceeded
        guard tunnelCleaned else {
            throw HelperError.commandFailed("awg-quick down failed with status \(down.status): \(down.stderr)")
        }
        try restoreDNSBaseline()
        clearRecoveryArtifacts()
        try? fileSystem.removeItem(at: namePath)
        if let persistenceError { throw persistenceError }
    }

    public func repair(currentSession: HelperSession?) throws -> HelperSession? {
        try refreshedSession(currentSession: currentSession)
    }

    public func hasManagedState() -> Bool {
        fileSystem.fileExists(at: paths.activeConfigPath)
            || fileSystem.fileExists(at: paths.amneziaNamePath(for: "active"))
    }

    public func refreshedSession(currentSession: HelperSession?) throws -> HelperSession? {
        guard var session = currentSession else { return nil }
        let socketPresent = fileSystem.fileExists(at: paths.runtimeSocketPath(for: session.interfaceName))
            || fileSystem.fileExists(at: paths.amneziaSocketPath(for: session.interfaceName))
        guard socketPresent else {
            // Without the userspace daemon's UAPI socket routes and DNS cannot
            // be healthy; skip the expensive route/scutil subprocess fan-out.
            session.socketExists = false
            session.routeInterface = nil
            session.ipv6RouteInterface = nil
            session.dnsHealthy = false
            session.antiLeakArmed = firewall.antileakIsActive()
            return session
        }
        let dump = try runner.run(CommandSpec(program: paths.awgPath, arguments: ["show", session.interfaceName, "dump"], timeout: 3))
        session.socketExists = dump.succeeded
        guard dump.succeeded else {
            session.routeInterface = nil
            session.ipv6RouteInterface = nil
            session.dnsHealthy = false
            session.antiLeakArmed = firewall.antileakIsActive()
            return session
        }
        let peer = dump.stdout.split(whereSeparator: \.isNewline).dropFirst().first?.split(separator: "\t", omittingEmptySubsequences: false)
        session.latestHandshake = peer.flatMap { $0.count > 4 ? UInt64($0[4]) : nil }
        session.rxBytes = peer.flatMap { $0.count > 5 ? UInt64($0[5]) : nil } ?? session.rxBytes
        session.txBytes = peer.flatMap { $0.count > 6 ? UInt64($0[6]) : nil } ?? session.txBytes
        session.routeInterface = routeInterface(for: "1.1.1.1")
        session.ipv6RouteInterface = ipv6FullTunnelRouteInterface()
        session.dnsHealthy = dnsIsConfigured(
            configPath: paths.activeConfigPath,
            interfaceName: session.interfaceName
        )
        session.antiLeakArmed = firewall.antileakIsActive()
        return session
    }

    private func resolvedConfigPath() throws -> String {
        let configured = (try? fileSystem.readText(at: paths.configPathFile))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configured.flatMap { $0.isEmpty ? nil : $0 } ?? paths.defaultConfigPath
        guard path.hasPrefix("/"), fileSystem.fileExists(at: path) else {
            throw HelperError.missingTunnelMetadata("missing VPN config at \(path)")
        }
        return path
    }

    private func resolvedInterfaceName(logicalInterface: String) throws -> String {
        let namePath = paths.amneziaNamePath(for: logicalInterface)
        let interfaceName = try fileSystem.readText(at: namePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard interfaceName.hasPrefix("utun"),
              interfaceName.dropFirst(4).allSatisfy(\.isNumber) else {
            throw HelperError.missingTunnelMetadata("invalid tunnel interface metadata at \(namePath)")
        }
        return interfaceName
    }

    private func endpoint(fromConfigAt path: String) throws -> String {
        for rawLine in try fileSystem.readText(at: path).split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let pieces = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pieces.count == 2, pieces[0].caseInsensitiveCompare("Endpoint") == .orderedSame {
                let endpoint = pieces[1]
                guard !endpoint.isEmpty else { break }
                return endpoint
            }
        }
        throw HelperError.missingTunnelMetadata("VPN config has no endpoint")
    }

    private func sanitizedConfig(from source: String) throws -> String {
        var output = [String]()
        var inInterface = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inInterface = trimmed.caseInsensitiveCompare("[Interface]") == .orderedSame
            }
            if inInterface, let key = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) {
                if ["PreUp", "PostUp", "PreDown", "PostDown"].contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                    throw HelperError.protocolViolation("VPN config lifecycle hooks are prohibited")
                }
                if key.caseInsensitiveCompare("SaveConfig") == .orderedSame {
                    continue
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private func killLingeringTunnelDaemon() {
        // A surviving userspace daemon holds the utun channel file descriptor,
        // which makes `ifconfig destroy` fail with EINVAL and strands the default
        // route in a dead interface (no internet). Release it before destroying.
        _ = try? runner.run(CommandSpec(program: "/usr/bin/pkill", arguments: ["-TERM", "-x", "amneziawg-go"], timeout: 2))
        _ = try? runner.run(CommandSpec(program: "/bin/sleep", arguments: ["1"], timeout: 2))
        _ = try? runner.run(CommandSpec(program: "/usr/bin/pkill", arguments: ["-9", "-x", "amneziawg-go"], timeout: 2))
    }

    private func fallbackInterfaceCleanup(_ interfaceName: String?) throws {
        guard let interfaceName,
              interfaceName.hasPrefix("utun"),
              interfaceName.dropFirst(4).allSatisfy(\.isNumber) else {
            throw HelperError.missingTunnelMetadata("missing valid interface identity for fallback cleanup")
        }
        killLingeringTunnelDaemon()
        var result = try runner.run(CommandSpec(program: "/sbin/ifconfig", arguments: [interfaceName, "destroy"], timeout: 5))
        if !result.succeeded {
            killLingeringTunnelDaemon()
            result = try runner.run(CommandSpec(program: "/sbin/ifconfig", arguments: [interfaceName, "destroy"], timeout: 5))
            if !result.succeeded {
                let probe = try runner.run(CommandSpec(program: "/sbin/ifconfig", arguments: [interfaceName], timeout: 3))
                guard !probe.succeeded else {
                    throw HelperError.commandFailed("fallback interface cleanup failed for \(interfaceName)")
                }
            }
        }
        try? fileSystem.removeItem(at: paths.runtimeSocketPath(for: interfaceName))
        try? fileSystem.removeItem(at: paths.amneziaSocketPath(for: interfaceName))
        if result.succeeded == false,
           fileSystem.fileExists(at: paths.runtimeSocketPath(for: interfaceName))
            || fileSystem.fileExists(at: paths.amneziaSocketPath(for: interfaceName)) {
            throw HelperError.commandFailed("fallback interface cleanup failed for \(interfaceName)")
        }
    }

    private func dnsIsConfigured(configPath: String, interfaceName: String) -> Bool {
        guard let config = try? fileSystem.readText(at: configPath) else { return false }
        let expected = Self.configuredDNSServers(config)
        if expected.isEmpty { return true }
        let result = try? runner.run(CommandSpec(program: "/usr/sbin/scutil", arguments: ["--dns"], timeout: 3))
        guard let result, result.succeeded else { return false }
        return Self.dnsOutput(result.stdout, contains: expected, forInterface: interfaceName)
    }

    static func dnsOutput(
        _ output: String,
        contains expectedServers: [String],
        forInterface interfaceName: String
    ) -> Bool {
        _ = interfaceName
        var resolverBlocks = [[String]]()
        var currentBlock = [String]()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #"), !currentBlock.isEmpty {
                resolverBlocks.append(currentBlock)
                currentBlock.removeAll(keepingCapacity: true)
            }
            currentBlock.append(line)
        }
        if !currentBlock.isEmpty {
            resolverBlocks.append(currentBlock)
        }

        guard let effectiveDefaultResolver = resolverBlocks.first(where: { block in
            block.first?.caseInsensitiveCompare("resolver #1") == .orderedSame
        }) else {
            return false
        }
        let nameservers = Set(effectiveDefaultResolver.compactMap { line -> String? in
            guard line.hasPrefix("nameserver["),
                  let separator = line.firstIndex(of: ":") else {
                return nil
            }
            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        })
        return expectedServers.allSatisfy {
            nameservers.contains($0.lowercased())
        }
    }

    static func configuredDNSServers(_ config: String) -> [String] {
        config.split(whereSeparator: \.isNewline).flatMap { rawLine -> [String] in
            let pieces = rawLine.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pieces.count == 2,
                  pieces[0].caseInsensitiveCompare("DNS") == .orderedSame else {
                return []
            }
            return pieces[1].split(separator: ",").compactMap { rawValue in
                let value = rawValue.trimmingCharacters(in: .whitespaces)
                var ipv4 = in_addr()
                var ipv6 = in6_addr()
                let isIPv4 = value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
                let isIPv6 = value.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
                return isIPv4 || isIPv6 ? value : nil
            }
        }
    }

    static func consistentIPv6FullTunnelInterface(_ interfaces: [String?]) -> String? {
        guard interfaces.count == 2,
              let first = interfaces[0],
              !first.isEmpty,
              interfaces[1] == first else {
            return nil
        }
        return first
    }

    private func captureDNSBaseline() throws {
        let list = try runner.run(CommandSpec(program: "/usr/sbin/networksetup", arguments: ["-listallnetworkservices"], timeout: 5))
        guard list.succeeded else { throw HelperError.commandFailed("could not list network services for DNS baseline") }
        var records = [String]()
        let services = list.stdout.split(whereSeparator: \.isNewline).dropFirst()
        for rawService in services {
            let service = String(rawService).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !service.isEmpty else { continue }
            let dns = try runner.run(CommandSpec(program: "/usr/sbin/networksetup", arguments: ["-getdnsservers", service], timeout: 3))
            let search = try runner.run(CommandSpec(program: "/usr/sbin/networksetup", arguments: ["-getsearchdomains", service], timeout: 3))
            guard dns.succeeded, search.succeeded else {
                throw HelperError.commandFailed("could not capture complete DNS baseline for \(service)")
            }
            records.append([service, dns.stdout, search.stdout].map {
                Data($0.utf8).base64EncodedString()
            }.joined(separator: "|"))
        }
        guard records.count == services.count else {
            throw HelperError.commandFailed("DNS baseline is incomplete")
        }
        try fileSystem.writeTextAtomically(records.joined(separator: "\n") + "\n", to: paths.dnsStatePath, mode: 0o600)
    }

    private func restoreDNSBaseline() throws {
        guard fileSystem.fileExists(at: paths.dnsStatePath) else {
            throw HelperError.missingTunnelMetadata("missing DNS recovery baseline")
        }
        for record in try fileSystem.readText(at: paths.dnsStatePath).split(whereSeparator: \.isNewline) {
            let fields = record.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let serviceData = Data(base64Encoded: String(fields[0])),
                  let dnsData = Data(base64Encoded: String(fields[1])),
                  let searchData = Data(base64Encoded: String(fields[2])),
                  let service = String(data: serviceData, encoding: .utf8),
                  let dnsText = String(data: dnsData, encoding: .utf8),
                  let searchText = String(data: searchData, encoding: .utf8) else {
                throw HelperError.io("invalid DNS recovery baseline")
            }
            let dnsValues = baselineValues(dnsText)
            let searchValues = baselineValues(searchText)
            let dns = try runner.run(CommandSpec(program: "/usr/sbin/networksetup", arguments: ["-setdnsservers", service] + dnsValues, timeout: 5))
            let search = try runner.run(CommandSpec(program: "/usr/sbin/networksetup", arguments: ["-setsearchdomains", service] + searchValues, timeout: 5))
            guard dns.succeeded, search.succeeded else {
                throw HelperError.commandFailed("could not restore DNS baseline for \(service)")
            }
        }
    }

    private func baselineValues(_ output: String) -> [String] {
        if output.localizedCaseInsensitiveContains("aren't any") || output.localizedCaseInsensitiveContains("not set") {
            return ["Empty"]
        }
        let values = output.split(whereSeparator: \.isWhitespace).map(String.init)
        return values.isEmpty ? ["Empty"] : values
    }

    private func clearRecoveryArtifacts() {
        try? fileSystem.removeItem(at: paths.activeConfigPath)
        try? fileSystem.removeItem(at: paths.dnsStatePath)
    }

    private func configHasIPv6DefaultRoute(_ path: String) -> Bool {
        guard let config = try? fileSystem.readText(at: path) else { return false }
        return config
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let compact = line.replacingOccurrences(of: " ", with: "")
                return compact.lowercased().hasPrefix("allowedips=") && compact.contains("::/0")
            }
    }

    private func runQuick(_ action: String, configPath: String) throws -> CommandResult {
        try runner.run(CommandSpec(
            program: paths.awgQuickPath,
            arguments: [action, configPath]
        ))
    }

    private func routeInterface(for destination: String) -> String? {
        let result = try? runner.run(CommandSpec(program: "/sbin/route", arguments: ["-n", "get", destination]))
        guard let result, result.succeeded else { return nil }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") })?
            .split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func ipv6FullTunnelRouteInterface() -> String? {
        Self.consistentIPv6FullTunnelInterface([
            routeInterface(for: "2001:4860:4860::8888"),
            routeInterface(for: "9000::1")
        ])
    }
}
