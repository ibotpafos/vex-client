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

    public init() {}

    public func createDirectory(at path: String) throws {
        try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func fileExists(at path: String) -> Bool {
        manager.fileExists(atPath: path)
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
        if let parent = destination.deletingLastPathComponent().path.removingPercentEncoding {
            try createDirectory(at: parent)
        }
        let nonce = UUID().uuidString
        let tempURL = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(nonce).tmp")
        let descriptor = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(mode))
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
                guard count > 0 else {
                    throw HelperError.io("could not write atomic temp file for \(path): \(String(cString: strerror(errno)))")
                }
                offset += count
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw HelperError.io("could not fsync atomic temp file for \(path)")
            }
            guard Darwin.fchmod(descriptor, mode_t(mode)) == 0 else {
                throw HelperError.io("could not chmod atomic temp file for \(path)")
            }
            guard Darwin.close(descriptor) == 0 else {
                throw HelperError.io("could not close atomic temp file for \(path)")
            }
            descriptorIsOpen = false
            guard Darwin.rename(tempURL.path, path) == 0 else {
                throw HelperError.io("could not atomically replace \(path): \(String(cString: strerror(errno)))")
            }
            let directoryFD = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if directoryFD >= 0 {
                _ = Darwin.fsync(directoryFD)
                _ = Darwin.close(directoryFD)
            }
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            _ = Darwin.unlink(tempURL.path)
            throw error
        }
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

    private func pfIsDisabled() throws -> Bool {
        let result = try runner.run(CommandSpec(program: "/sbin/pfctl", arguments: ["-s", "info"]))
        guard result.succeeded else {
            throw HelperError.commandFailed("pfctl -s info failed with status \(result.status)")
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Status: Disabled" }
    }

    private func buildRules(endpoint: String, interfaceName: String) -> String {
        let host = endpoint.split(separator: ":", maxSplits: 1).first.map(String.init) ?? endpoint
        let port = endpoint.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        var rules = "set block-policy drop\npass quick on lo0 all\npass out quick on \(interfaceName) all\n"
        if !host.isEmpty {
            if !port.isEmpty {
                rules += "pass out quick inet proto udp from any to \(host) port = \(port) keep state\n"
            }
            rules += "pass out quick inet proto tcp from any to \(host) port = 443 keep state\n"
            rules += "pass out quick inet proto tcp from any to \(host) port = 22 keep state\n"
        }
        for protectedHost in ["94.141.160.212", "31.77.199.171"] {
            rules += "pass out quick inet proto tcp from any to \(protectedHost) port = 443 keep state\n"
            rules += "pass out quick inet proto tcp from any to \(protectedHost) port = 22 keep state\n"
        }
        rules += "block drop out all\n"
        return rules
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

    public func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession {
        if currentSession != nil || hasManagedState() || firewall.antileakIsActive() {
            try bringDown(currentSession: currentSession)
        }

        let sourceConfigPath = try resolvedConfigPath()
        let sanitized = try sanitizedConfig(from: fileSystem.readText(at: sourceConfigPath))
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
        let dump = try runner.run(CommandSpec(program: paths.awgPath, arguments: ["show", session.interfaceName, "dump"], timeout: 3))
        session.socketExists = socketPresent && dump.succeeded
        if dump.succeeded {
            let peer = dump.stdout.split(whereSeparator: \.isNewline).dropFirst().first?.split(separator: "\t", omittingEmptySubsequences: false)
            session.latestHandshake = peer.flatMap { $0.count > 4 ? UInt64($0[4]) : nil }
            session.rxBytes = peer.flatMap { $0.count > 5 ? UInt64($0[5]) : nil } ?? session.rxBytes
            session.txBytes = peer.flatMap { $0.count > 6 ? UInt64($0[6]) : nil } ?? session.txBytes
        }
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
