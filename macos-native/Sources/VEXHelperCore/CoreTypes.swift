import Darwin
import Foundation

public struct HelperPathsLayout: Sendable, Equatable {
    public var helperDirectory: String
    public var socketPath: String
    public var ownerSessionPath: String
    public var operationLockPath: String
    public var antileakStatePath: String
    public var legacyAntileakStatePath: String
    public var antileakAnchorPath: String
    public var sessionStatePath: String
    public var interfacePath: String
    public var endpointPath: String
    public var runtimeDirectory: String
    public var amneziaRuntimeDirectory: String
    public var awgQuickPath: String
    public var configPathFile: String
    public var defaultConfigPath: String
    public var activeConfigPath: String
    public var dnsStatePath: String
    public var awgPath: String
    public var pfConfigPath: String

    public init(
        helperDirectory: String = "/Library/Application Support/VEX VPN/helper",
        socketPath: String = "/var/run/vex-helper.sock",
        ownerSessionPath: String = "/Library/Application Support/VEX VPN/helper/owner.state",
        operationLockPath: String = "/Library/Application Support/VEX VPN/helper/operation.lock",
        antileakStatePath: String = "/Library/Application Support/VEX VPN/helper/antileak.state",
        legacyAntileakStatePath: String = "/Library/Application Support/VEX VPN/helper/antileak.active",
        antileakAnchorPath: String = "/etc/pf.anchors/com.vexguard.antileak",
        sessionStatePath: String = "/Library/Application Support/VEX VPN/helper/session.state",
        interfacePath: String = "/Library/Application Support/VEX VPN/helper/utun.name",
        endpointPath: String = "/Library/Application Support/VEX VPN/helper/endpoint.txt",
        runtimeDirectory: String = "/var/run/wireguard",
        amneziaRuntimeDirectory: String = "/var/run/amneziawg",
        awgQuickPath: String = "/Library/Application Support/VEX VPN/helper/awg-quick.sh",
        configPathFile: String = "/Library/Application Support/VEX VPN/helper/config-path",
        defaultConfigPath: String = "/etc/amnezia/amneziawg/tun0.conf",
        activeConfigPath: String = "/Library/Application Support/VEX VPN/helper/active.conf",
        dnsStatePath: String = "/Library/Application Support/VEX VPN/helper/dns-baseline.state",
        awgPath: String = "/Library/Application Support/VEX VPN/helper/awg",
        pfConfigPath: String = "/etc/pf.conf"
    ) {
        self.helperDirectory = helperDirectory
        self.socketPath = socketPath
        self.ownerSessionPath = ownerSessionPath
        self.operationLockPath = operationLockPath
        self.antileakStatePath = antileakStatePath
        self.legacyAntileakStatePath = legacyAntileakStatePath
        self.antileakAnchorPath = antileakAnchorPath
        self.sessionStatePath = sessionStatePath
        self.interfacePath = interfacePath
        self.endpointPath = endpointPath
        self.runtimeDirectory = runtimeDirectory
        self.amneziaRuntimeDirectory = amneziaRuntimeDirectory
        self.awgQuickPath = awgQuickPath
        self.configPathFile = configPathFile
        self.defaultConfigPath = defaultConfigPath
        self.activeConfigPath = activeConfigPath
        self.dnsStatePath = dnsStatePath
        self.awgPath = awgPath
        self.pfConfigPath = pfConfigPath
    }

    public func runtimeSocketPath(for interfaceName: String) -> String {
        "\(runtimeDirectory)/\(interfaceName).sock"
    }

    public func amneziaSocketPath(for interfaceName: String) -> String {
        "\(amneziaRuntimeDirectory)/\(interfaceName).sock"
    }

    public func amneziaNamePath(for logicalInterface: String) -> String {
        "\(amneziaRuntimeDirectory)/\(logicalInterface).name"
    }
}

public enum HelperCommand: Equatable, Sendable {
    case up(armAntiLeak: Bool, ownerPID: Int32?)
    case down
    case shutdown
    case repair
    case status
    case diagnostics
    case attachOwner(ownerPID: Int32)
    case antiLeakOff

    public static func parse(_ rawValue: String) throws -> HelperCommand {
        let parts = rawValue.split(whereSeparator: \.isWhitespace).map(String.init)
        let commandName = parts.first ?? ""
        let metadata = Array(parts.dropFirst())

        switch commandName {
        case "up":
            return .up(armAntiLeak: true, ownerPID: try parseOwnerPIDMetadata(metadata))
        case "up-no-antileak":
            return .up(armAntiLeak: false, ownerPID: try parseOwnerPIDMetadata(metadata))
        case "down":
            try ensureNoCommandMetadata(metadata)
            return .down
        case "shutdown":
            try ensureNoCommandMetadata(metadata)
            return .shutdown
        case "repair":
            try ensureNoCommandMetadata(metadata)
            return .repair
        case "status":
            try ensureNoCommandMetadata(metadata)
            return .status
        case "diagnostics":
            try ensureNoCommandMetadata(metadata)
            return .diagnostics
        case "attach-owner":
            guard let ownerPID = try parseOwnerPIDMetadata(metadata) else {
                throw HelperError.protocolViolation("attach-owner requires owner_pid")
            }
            return .attachOwner(ownerPID: ownerPID)
        case "antileak-off":
            try ensureNoCommandMetadata(metadata)
            return .antiLeakOff
        case "":
            throw HelperError.protocolViolation("empty command")
        default:
            throw HelperError.protocolViolation("unknown command \(commandName)")
        }
    }

    private static func parseOwnerPIDMetadata(_ metadata: [String]) throws -> Int32? {
        var ownerPID: Int32?
        for item in metadata {
            let value: String
            if let suffix = item.split(separator: "=", maxSplits: 1).dropFirst().first,
               item.hasPrefix("owner_pid=") || item.hasPrefix("owner-pid=") {
                value = String(suffix)
            } else {
                throw HelperError.protocolViolation("unsupported command metadata \(item)")
            }

            guard let parsed = Int32(value), parsed > 1 else {
                throw HelperError.protocolViolation("invalid owner_pid \(value)")
            }
            guard ownerPID == nil else {
                throw HelperError.protocolViolation("duplicate owner_pid metadata")
            }
            ownerPID = parsed
        }
        return ownerPID
    }

    private static func ensureNoCommandMetadata(_ metadata: [String]) throws {
        guard metadata.isEmpty else {
            throw HelperError.protocolViolation("unsupported command metadata \(metadata.joined(separator: " "))")
        }
    }
}

public enum HelperError: Error, LocalizedError, Equatable, Sendable {
    case socketCreateFailed
    case invalidSocketPath
    case socketBindFailed(String)
    case socketAcceptFailed(String)
    case commandTooLong(limit: Int)
    case readFailed(String)
    case writeFailed(String)
    case protocolViolation(String)
    case operationInProgress
    case commandFailed(String)
    case ownerVerificationFailed(String)
    case missingTunnelMetadata(String)
    case pfPersistenceAfterRuntimeClear(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed:
            return "could not create Unix socket"
        case .invalidSocketPath:
            return "invalid helper socket path"
        case .socketBindFailed(let detail):
            return "could not bind helper socket (\(detail))"
        case .socketAcceptFailed(let detail):
            return "could not accept helper socket client (\(detail))"
        case .commandTooLong:
            return "command too long"
        case .readFailed(let detail):
            return "could not read helper command (\(detail))"
        case .writeFailed(let detail):
            return "could not write helper response (\(detail))"
        case .protocolViolation(let detail):
            return detail
        case .operationInProgress:
            return "operation already in progress"
        case .commandFailed(let detail):
            return detail
        case .ownerVerificationFailed(let detail):
            return detail
        case .missingTunnelMetadata(let detail):
            return detail
        case .pfPersistenceAfterRuntimeClear(let detail):
            return "PF runtime rules were cleared, but persistent recovery state is pending: \(detail)"
        case .io(let detail):
            return detail
        }
    }

    public var socketMessage: String {
        "error: \(errorDescription ?? "unknown helper error")\n"
    }
}

public struct OwnerSession: Equatable, Sendable {
    public var pid: Int32
    public var token: String
    public var identity: String

    public init(pid: Int32, token: String, identity: String) {
        self.pid = pid
        self.token = token
        self.identity = identity
    }

    public init?(payload: String) {
        var pid: Int32?
        var token: String?
        var identity: String?
        for line in payload.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let value = text.split(separator: "=", maxSplits: 1).dropFirst().first, text.hasPrefix("pid=") {
                pid = Int32(value)
            } else if let value = text.split(separator: "=", maxSplits: 1).dropFirst().first, text.hasPrefix("token=") {
                token = String(value)
            } else if let value = text.split(separator: "=", maxSplits: 1).dropFirst().first, text.hasPrefix("identity=") {
                identity = String(value)
            }
        }
        guard let pid, let token, let identity else { return nil }
        self.init(pid: pid, token: token, identity: identity)
    }

    public var payload: String {
        "pid=\(pid)\ntoken=\(token)\nidentity=\(identity)\n"
    }
}

public struct HelperSession: Equatable, Sendable {
    public var interfaceName: String
    public var endpoint: String
    public var ownerPID: Int32?
    public var routeInterface: String?
    public var ipv6RouteInterface: String?
    public var socketExists: Bool
    public var antiLeakArmed: Bool
    public var ipv6RouteExpected: Bool
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var latestHandshake: UInt64?
    public var startedAt: UInt64
    public var dnsHealthy: Bool

    public init(
        interfaceName: String,
        endpoint: String,
        ownerPID: Int32? = nil,
        routeInterface: String? = nil,
        ipv6RouteInterface: String? = nil,
        socketExists: Bool = false,
        antiLeakArmed: Bool = false,
        ipv6RouteExpected: Bool = false,
        rxBytes: UInt64 = 0,
        txBytes: UInt64 = 0,
        latestHandshake: UInt64? = nil,
        startedAt: UInt64 = UInt64(Date().timeIntervalSince1970),
        dnsHealthy: Bool = true
    ) {
        self.interfaceName = interfaceName
        self.endpoint = endpoint
        self.ownerPID = ownerPID
        self.routeInterface = routeInterface
        self.ipv6RouteInterface = ipv6RouteInterface
        self.socketExists = socketExists
        self.antiLeakArmed = antiLeakArmed
        self.ipv6RouteExpected = ipv6RouteExpected
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.latestHandshake = latestHandshake
        self.startedAt = startedAt
        self.dnsHealthy = dnsHealthy
    }

    public init?(payload: String) {
        var values = [String: String]()
        for line in payload.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            values[String(pieces[0])] = String(pieces[1])
        }
        guard let interfaceName = values["iface"], !interfaceName.isEmpty else { return nil }
        let endpoint = values["endpoint"] ?? ""
        self.init(
            interfaceName: interfaceName,
            endpoint: endpoint,
            ownerPID: values["owner_pid"].flatMap(Int32.init),
            routeInterface: values["route_iface"],
            ipv6RouteInterface: values["ipv6_route_iface"],
            socketExists: values["socket_exists"] == "true",
            antiLeakArmed: values["antileak"] == "armed",
            ipv6RouteExpected: values["ipv6_route_expected"] == "true",
            rxBytes: values["rx"].flatMap(UInt64.init) ?? 0,
            txBytes: values["tx"].flatMap(UInt64.init) ?? 0,
            latestHandshake: values["latest_handshake"].flatMap(UInt64.init),
            startedAt: values["started_at"].flatMap(UInt64.init) ?? 0,
            dnsHealthy: values["dns_healthy"] != "false"
        )
    }

    public var payload: String {
        [
            "iface=\(interfaceName)",
            "endpoint=\(endpoint)",
            "owner_pid=\(ownerPID.map(String.init) ?? "")",
            "route_iface=\(routeInterface ?? "")",
            "ipv6_route_iface=\(ipv6RouteInterface ?? "")",
            "socket_exists=\(socketExists)",
            "antileak=\(antiLeakArmed ? "armed" : "off")",
            "ipv6_route_expected=\(ipv6RouteExpected)",
            "rx=\(rxBytes)",
            "tx=\(txBytes)",
            "latest_handshake=\(latestHandshake ?? 0)",
            "started_at=\(startedAt)",
            "dns_healthy=\(dnsHealthy)"
        ].joined(separator: "\n") + "\n"
    }
}

public struct HelperStatusSnapshot: Equatable, Sendable {
    public var operationInProgress: Bool
    public var interfaceName: String
    public var endpoint: String
    public var socketExists: Bool
    public var routeOK: Bool
    public var routeInterface: String
    public var ipv6RouteExpected: Bool
    public var ipv6RouteOK: Bool
    public var ipv6RouteInterface: String
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var latestHandshake: UInt64
    public var leakProtection: String

    public init(
        operationInProgress: Bool,
        interfaceName: String,
        endpoint: String,
        socketExists: Bool,
        routeOK: Bool,
        routeInterface: String,
        ipv6RouteExpected: Bool,
        ipv6RouteOK: Bool,
        ipv6RouteInterface: String,
        rxBytes: UInt64,
        txBytes: UInt64,
        latestHandshake: UInt64,
        leakProtection: String
    ) {
        self.operationInProgress = operationInProgress
        self.interfaceName = interfaceName
        self.endpoint = endpoint
        self.socketExists = socketExists
        self.routeOK = routeOK
        self.routeInterface = routeInterface
        self.ipv6RouteExpected = ipv6RouteExpected
        self.ipv6RouteOK = ipv6RouteOK
        self.ipv6RouteInterface = ipv6RouteInterface
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.latestHandshake = latestHandshake
        self.leakProtection = leakProtection
    }

    public var state: String {
        if operationInProgress {
            return "connecting"
        }
        let ipv6Ready = !ipv6RouteExpected || ipv6RouteOK
        if routeOK, ipv6Ready, !interfaceName.isEmpty, socketExists {
            return "connected"
        }
        if (!interfaceName.isEmpty && socketExists) || leakProtection == "armed" {
            return "error"
        }
        return "disconnected"
    }

    public var statusResponse: String {
        "state=\(state) operation_in_progress=\(operationInProgress) iface=\(interfaceName) endpoint=\(endpoint) socket_exists=\(socketExists) route_ok=\(routeOK) route_iface=\(routeInterface) ipv6_route_expected=\(ipv6RouteExpected) ipv6_route_ok=\(ipv6RouteOK) ipv6_route_iface=\(ipv6RouteInterface) rx=\(rxBytes) tx=\(txBytes) latest_handshake=\(latestHandshake) leak_protection=\(leakProtection)\n"
    }

    public var diagnosticsResponse: String {
        "operation_in_progress=\(operationInProgress)\niface=\(interfaceName)\nendpoint=\(endpoint)\nsocket_exists=\(socketExists)\nroute_ok=\(routeOK)\nroute_iface=\(routeInterface)\nipv6_route_expected=\(ipv6RouteExpected)\nipv6_route_ok=\(ipv6RouteOK)\nipv6_route_iface=\(ipv6RouteInterface)\nrx=\(rxBytes)\ntx=\(txBytes)\nlatest_handshake=\(latestHandshake)\nleak_protection=\(leakProtection)\n"
    }
}

public struct CommandSpec: Equatable, Hashable, Sendable {
    public var program: String
    public var arguments: [String]
    public var timeout: TimeInterval

    public init(program: String, arguments: [String], timeout: TimeInterval = 15) {
        self.program = program
        self.arguments = arguments
        self.timeout = timeout
    }
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public protocol CommandRunning: Sendable {
    func run(_ spec: CommandSpec) throws -> CommandResult
}

public protocol HelperFileSystem: Sendable {
    func createDirectory(at path: String) throws
    func fileExists(at path: String) -> Bool
    func fileSize(at path: String) -> UInt64?
    func modificationDate(at path: String) -> Date?
    func readText(at path: String) throws -> String
    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws
    func removeItem(at path: String) throws
}

public protocol ProcessInspecting: Sendable {
    func processIdentity(pid: Int32) -> String?
}

public protocol TunnelControlling: Sendable {
    func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession
    func bringDown(currentSession: HelperSession?) throws
    func repair(currentSession: HelperSession?) throws -> HelperSession?
    func refreshedSession(currentSession: HelperSession?) throws -> HelperSession?
    func hasManagedState() -> Bool
}

public extension TunnelControlling {
    func hasManagedState() -> Bool { false }
}

public protocol PFFirewallControlling: Sendable {
    func antileakIsActive() -> Bool
    func enable(endpoint: String, interfaceName: String) throws
    func disable() throws
}

public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

public protocol AsyncSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct TaskSleeper: AsyncSleeping {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public protocol HelperLogging: Sendable {
    func info(_ component: String, _ message: String)
    func warn(_ component: String, _ message: String)
    func error(_ component: String, _ message: String)
}

public struct StderrLogger: HelperLogging {
    public init() {}

    public func info(_ component: String, _ message: String) {
        emit(level: "INFO", component: component, message: message)
    }

    public func warn(_ component: String, _ message: String) {
        emit(level: "WARN", component: component, message: message)
    }

    public func error(_ component: String, _ message: String) {
        emit(level: "ERROR", component: component, message: message)
    }

    private func emit(level: String, component: String, message: String) {
        fputs("[vex-swift-helper][\(level)][\(component)] \(message)\n", stderr)
    }
}

public enum HelperCommandFrame {
    public static func decode(_ bytes: [UInt8], maxBytes: Int) throws -> String? {
        guard bytes.count <= maxBytes else {
            throw HelperError.commandTooLong(limit: maxBytes)
        }
        guard bytes.last == 10 else {
            throw HelperError.protocolViolation("unterminated command frame")
        }
        let prefix = Array(bytes.dropLast())
        guard !prefix.contains(0),
              let decoded = String(bytes: prefix, encoding: .utf8) else {
            throw HelperError.protocolViolation("command frame is not valid UTF-8")
        }
        let command = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
