import Darwin
import Foundation
import SystemConfiguration

public struct HelperRuntimeConfiguration: Sendable {
    public var maxCommandBytes: Int
    public var commandTimeout: TimeInterval
    public var ownerWatchdogInterval: Duration
    public var routeWatchdogInterval: Duration
    public var operationLockStaleAfter: TimeInterval
    public var handshakeStarveFailOpenTicks: Int

    public init(
        maxCommandBytes: Int = 512,
        commandTimeout: TimeInterval = 5,
        ownerWatchdogInterval: Duration = .seconds(4),
        routeWatchdogInterval: Duration = .seconds(2),
        operationLockStaleAfter: TimeInterval = 120,
        handshakeStarveFailOpenTicks: Int = 10
    ) {
        self.maxCommandBytes = maxCommandBytes
        self.commandTimeout = commandTimeout
        self.ownerWatchdogInterval = ownerWatchdogInterval
        self.routeWatchdogInterval = routeWatchdogInterval
        self.operationLockStaleAfter = operationLockStaleAfter
        self.handshakeStarveFailOpenTicks = handshakeStarveFailOpenTicks
    }
}

public struct HelperCommandResponse: Equatable, Sendable {
    public var payload: String
    public var shouldExit: Bool

    public init(payload: String, shouldExit: Bool = false) {
        self.payload = payload
        self.shouldExit = shouldExit
    }
}

public actor HelperRuntime {
    private let store: HelperStateStore
    private let tunnelController: TunnelControlling
    private let firewallController: PFFirewallControlling
    private let processInspector: ProcessInspecting
    private let dateProvider: DateProviding
    private let sleeper: AsyncSleeping
    private let logger: HelperLogging
    private let configuration: HelperRuntimeConfiguration

    private var ownerWatchdogTask: Task<Void, Never>?
    private var routeWatchdogTask: Task<Void, Never>?
    private var unhealthyTunnelTicks = 0
    private var handshakeStarvedTicks = 0

    public init(
        store: HelperStateStore,
        tunnelController: TunnelControlling,
        firewallController: PFFirewallControlling,
        processInspector: ProcessInspecting,
        dateProvider: DateProviding = SystemDateProvider(),
        sleeper: AsyncSleeping = TaskSleeper(),
        logger: HelperLogging = StderrLogger(),
        configuration: HelperRuntimeConfiguration = .init()
    ) {
        self.store = store
        self.tunnelController = tunnelController
        self.firewallController = firewallController
        self.processInspector = processInspector
        self.dateProvider = dateProvider
        self.sleeper = sleeper
        self.logger = logger
        self.configuration = configuration
    }

    public func bootstrap() async throws {
        do {
            try store.ensureDirectories()
        } catch {
            // PF cleanup must not depend on a writable state directory. If the
            // root-owned store is damaged after a crash, flush live anti-leak
            // rules first so launchd retries cannot strand the host offline.
            logger.error("bootstrap", "state directory unavailable; forcing fail-open cleanup")
            do {
                try firewallController.disable()
            } catch {
                logger.error("bootstrap", "emergency PF cleanup failed: \(error.localizedDescription)")
            }
            let session = store.loadSession()
            if session != nil || tunnelController.hasManagedState() {
                do {
                    try tunnelController.bringDown(currentSession: session)
                } catch {
                    logger.error("bootstrap", "emergency tunnel cleanup failed: \(error.localizedDescription)")
                }
            }
            throw error
        }
        await recoverStrandedAntiLeak()
        await resumeOwnerWatchdog()
        startRouteWatchdogLoopIfNeeded()
    }

    public func handle(commandLine: String, peerPID: Int32?) async -> HelperCommandResponse {
        do {
            let command = try HelperCommand.parse(commandLine)
            return try await execute(command: command, peerPID: peerPID)
        } catch let error as HelperError {
            if !commandLine.hasPrefix("status") {
                logger.warn("socket", error.localizedDescription)
            }
            return HelperCommandResponse(payload: error.socketMessage)
        } catch {
            logger.error("socket", "unexpected error: \(error.localizedDescription)")
            return HelperCommandResponse(payload: HelperError.io(error.localizedDescription).socketMessage)
        }
    }

    public func snapshotStatus() async -> HelperStatusSnapshot {
        let session = (try? tunnelController.refreshedSession(currentSession: store.loadSession())) ?? store.loadSession()
        return makeStatusSnapshot(from: session)
    }

    public func runOwnerWatchdogTick() async {
        guard let ownerSession = store.loadOwnerSession() else { return }
        let currentIdentity = processInspector.processIdentity(pid: ownerSession.pid)
        guard currentIdentity != ownerSession.identity else { return }
        logger.warn("watchdog", "owner pid \(ownerSession.pid) exited; releasing VEX tunnel")
        do {
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                try actionDownWithoutLock()
            }
            store.clearOwnerSession()
        } catch {
            logger.warn("watchdog", "cleanup failed; will retry: \(error.localizedDescription)")
        }
    }

    public func runRouteWatchdogTick() async {
        guard let session = (try? tunnelController.refreshedSession(currentSession: store.loadSession())) ?? store.loadSession() else {
            unhealthyTunnelTicks += 1
            if unhealthyTunnelTicks >= 2 {
                await recoverStrandedAntiLeak()
            }
            return
        }
        if tunnelIsHealthy(session) {
            unhealthyTunnelTicks = 0
            try? store.persistSession(session)
            let establishedHandshake = session.latestHandshake.flatMap { $0 == 0 ? nil : $0 }
            if establishedHandshake != nil {
                handshakeStarvedTicks = 0
                return
            }
            handshakeStarvedTicks += 1
            if handshakeStarvedTicks >= configuration.handshakeStarveFailOpenTicks {
                do {
                    try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                        try actionDownWithoutLock()
                    }
                    handshakeStarvedTicks = 0
                    logger.warn("route-watchdog", "tunnel never established a handshake; fail-open teardown completed")
                } catch {
                    logger.error("route-watchdog", "fail-open teardown will retry: \(error.localizedDescription)")
                }
            }
            return
        }
        handshakeStarvedTicks = 0
        unhealthyTunnelTicks += 1
        do {
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                let repaired = try tunnelController.repair(currentSession: session)
                if let repaired, tunnelIsHealthy(repaired) {
                    try store.persistSession(repaired)
                    unhealthyTunnelTicks = 0
                    return
                }
                throw HelperError.commandFailed("tunnel health did not recover after route repair")
            }
        } catch {
            logger.warn("route-watchdog", "repair deferred: \(error.localizedDescription)")
            if unhealthyTunnelTicks >= 2 {
                do {
                    try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                        try actionDownWithoutLock()
                    }
                    unhealthyTunnelTicks = 0
                    logger.warn("route-watchdog", "tunnel remained unhealthy; fail-open teardown completed")
                } catch {
                    logger.error("route-watchdog", "fail-open teardown will retry: \(error.localizedDescription)")
                }
            }
        }
    }

    public func recoverStrandedAntiLeak() async {
        let persistedSession = store.loadSession()
        let firewallActive = firewallController.antileakIsActive()
        guard firewallActive || persistedSession != nil || tunnelController.hasManagedState() else { return }
        let currentSession = (try? tunnelController.refreshedSession(currentSession: persistedSession)) ?? persistedSession
        let owner = store.loadOwnerSession()
        let ownerIsValid = owner.map { processInspector.processIdentity(pid: $0.pid) == $0.identity } ?? false
        if let currentSession, tunnelIsHealthy(currentSession), ownerIsValid {
            return
        }
        logger.warn("bootstrap", "managed network state exists without a live owner; starting fail-open recovery")
        do {
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                if persistedSession != nil || tunnelController.hasManagedState() {
                    try actionDownWithoutLock()
                } else {
                    try firewallController.disable()
                    store.clearOwnerSession()
                }
            }
        } catch {
            logger.warn("bootstrap", "fail-open recovery deferred: \(error.localizedDescription)")
        }
    }

    public func resumeOwnerWatchdog() async {
        guard let existing = store.loadOwnerSession() else { return }
        guard processInspector.processIdentity(pid: existing.pid) == existing.identity else {
            do {
                try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                    try actionDownWithoutLock()
                }
                store.clearOwnerSession()
            } catch {
                logger.warn("watchdog", "could not resume owner watchdog cleanly: \(error.localizedDescription)")
            }
            return
        }
        do {
            try armOwnerWatchdog(ownerPID: existing.pid)
        } catch {
            logger.error("watchdog", "could not resume owner watchdog: \(error.localizedDescription)")
            do {
                try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                    try actionDownWithoutLock()
                }
            } catch {
                logger.error("watchdog", "fail-open cleanup will retry: \(error.localizedDescription)")
            }
        }
    }

    public nonisolated static func makeDefault() -> HelperRuntime {
        let paths = HelperPathsLayout()
        let fileSystem = LocalFileSystem()
        let runner = ProcessRunner()
        let logger = StderrLogger()
        let firewall = SystemPFFirewallController(runner: runner, fileSystem: fileSystem, paths: paths, logger: logger)
        let tunnel = SystemTunnelController(fileSystem: fileSystem, paths: paths, runner: runner, firewall: firewall)
        let store = HelperStateStore(fileSystem: fileSystem, paths: paths)
        return HelperRuntime(
            store: store,
            tunnelController: tunnel,
            firewallController: firewall,
            processInspector: SystemProcessInspector(),
            logger: logger
        )
    }

    private func execute(command: HelperCommand, peerPID: Int32?) async throws -> HelperCommandResponse {
        switch command {
        case .status:
            return HelperCommandResponse(payload: makeStatusSnapshot(from: try tunnelController.refreshedSession(currentSession: store.loadSession())).statusResponse)
        case .diagnostics:
            return HelperCommandResponse(payload: makeStatusSnapshot(from: try tunnelController.refreshedSession(currentSession: store.loadSession())).diagnosticsResponse)
        case .up(let armAntiLeak, let ownerPID):
            let verified = try verifiedOwnerPID(requested: ownerPID, peerPID: peerPID)
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                let session = try tunnelController.bringUp(currentSession: store.loadSession(), armAntiLeak: armAntiLeak, ownerPID: verified)
                try store.persistSession(session)
            }
            do {
                try armOwnerWatchdog(ownerPID: verified)
            } catch {
                try? store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                    try actionDownWithoutLock()
                }
                throw error
            }
            return HelperCommandResponse(payload: "ok\n")
        case .down:
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                try actionDownWithoutLock()
            }
            return HelperCommandResponse(payload: "ok\n")
        case .shutdown:
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                try actionDownWithoutLock()
            }
            return HelperCommandResponse(payload: "ok\n", shouldExit: true)
        case .repair:
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                if let repaired = try tunnelController.repair(currentSession: store.loadSession()) {
                    try store.persistSession(repaired)
                }
            }
            return HelperCommandResponse(payload: "ok\n")
        case .attachOwner(let ownerPID):
            let verified = try verifiedOwnerPID(requested: ownerPID, peerPID: peerPID)
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                guard let verified else {
                    throw HelperError.ownerVerificationFailed("could not verify owner_pid against socket peer")
                }
                try persistOwnerSession(ownerPID: verified)
            }
            try armOwnerWatchdog(ownerPID: verified)
            return HelperCommandResponse(payload: "ok\n")
        case .antiLeakOff:
            try store.withOperationLock(staleAfter: configuration.operationLockStaleAfter) {
                try firewallController.disable()
                if var session = store.loadSession() {
                    session.antiLeakArmed = false
                    try store.persistSession(session)
                }
            }
            return HelperCommandResponse(payload: "ok\n")
        }
    }

    private func actionDownWithoutLock() throws {
        let session = store.loadSession()
        do {
            try tunnelController.bringDown(currentSession: session)
        } catch let error as HelperError {
            guard case .pfPersistenceAfterRuntimeClear = error else { throw error }
            // Live PF, tunnel, routes and DNS are already fail-open. Clear the
            // session so the route watchdog can retry only the durable PF state.
            store.clearSession()
            store.clearOwnerSession()
            ownerWatchdogTask?.cancel()
            ownerWatchdogTask = nil
            throw error
        }
        store.clearSession()
        store.clearOwnerSession()
        ownerWatchdogTask?.cancel()
        ownerWatchdogTask = nil
    }

    private func tunnelIsHealthy(_ session: HelperSession) -> Bool {
        guard session.socketExists,
              !session.interfaceName.isEmpty,
              session.routeInterface == session.interfaceName,
              session.dnsHealthy else {
            return false
        }
        // A quiet WireGuard peer can legitimately keep an old handshake while
        // routes, DNS and the local UAPI socket remain healthy. Handshake age is
        // diagnostic data, not a reason for the privileged helper to tear down
        // a structurally valid tunnel.
        return !session.ipv6RouteExpected
            || session.ipv6RouteInterface == session.interfaceName
    }

    private func makeStatusSnapshot(from session: HelperSession??) -> HelperStatusSnapshot {
        let session = session ?? nil
        let operation = store.operationInProgress(staleAfter: configuration.operationLockStaleAfter)
        let interfaceName = session?.interfaceName ?? ""
        let routeInterface = session?.routeInterface ?? ""
        let ipv6Expected = session?.ipv6RouteExpected ?? false
        let ipv6RouteInterface = session?.ipv6RouteInterface ?? ""
        let routeOK = !interfaceName.isEmpty && routeInterface == interfaceName
        let ipv6OK = !ipv6Expected
            || (!interfaceName.isEmpty && ipv6RouteInterface == interfaceName)
        return HelperStatusSnapshot(
            operationInProgress: operation,
            interfaceName: interfaceName,
            endpoint: session?.endpoint ?? "",
            socketExists: session?.socketExists ?? false,
            routeOK: routeOK,
            routeInterface: routeInterface,
            ipv6RouteExpected: ipv6Expected,
            ipv6RouteOK: ipv6OK,
            ipv6RouteInterface: ipv6RouteInterface,
            rxBytes: session?.rxBytes ?? 0,
            txBytes: session?.txBytes ?? 0,
            latestHandshake: session?.latestHandshake ?? 0,
            leakProtection: (session?.antiLeakArmed ?? false) || firewallController.antileakIsActive() ? "armed" : "off"
        )
    }

    private func verifiedOwnerPID(requested: Int32?, peerPID: Int32?) throws -> Int32? {
        switch (requested, peerPID) {
        case let (requested?, peerPID?) where requested == peerPID:
            return requested
        case let (requested?, peerPID?):
            throw HelperError.ownerVerificationFailed("owner_pid \(requested) does not match socket peer \(peerPID)")
        case (.some, .none):
            throw HelperError.ownerVerificationFailed("could not verify owner_pid against socket peer")
        case (.none, let peerPID):
            return peerPID
        }
    }

    private func persistOwnerSession(ownerPID: Int32) throws {
        let sessionID = "\(ownerPID)-\(Int(dateProvider.now.timeIntervalSince1970 * 1000))"
        guard let identity = processInspector.processIdentity(pid: ownerPID) else {
            throw HelperError.commandFailed("could not capture owner process identity for \(ownerPID)")
        }
        try store.persistOwnerSession(OwnerSession(pid: ownerPID, token: sessionID, identity: identity))
    }

    private func armOwnerWatchdog(ownerPID: Int32?) throws {
        ownerWatchdogTask?.cancel()
        guard let ownerPID else {
            store.clearOwnerSession()
            return
        }
        if let session = store.loadOwnerSession(), session.pid != ownerPID {
            try persistOwnerSession(ownerPID: ownerPID)
        } else if store.loadOwnerSession() == nil {
            try persistOwnerSession(ownerPID: ownerPID)
        }
        ownerWatchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await self.sleeper.sleep(for: self.configuration.ownerWatchdogInterval)
                } catch {
                    return
                }
                await self.runOwnerWatchdogTick()
            }
        }
    }

    private func startRouteWatchdogLoopIfNeeded() {
        guard routeWatchdogTask == nil else { return }
        routeWatchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await self.sleeper.sleep(for: self.configuration.routeWatchdogInterval)
                } catch {
                    return
                }
                await self.runRouteWatchdogTick()
            }
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let configuration: HelperRuntimeConfiguration
    private let logger: HelperLogging
    private let authenticator: PeerAuthenticating
    private var listener: Int32 = -1
    private var ownershipMonitorRunning = false
    private let ownershipMonitorLock = NSLock()

    public init(
        socketPath: String,
        configuration: HelperRuntimeConfiguration = .init(),
        logger: HelperLogging = StderrLogger(),
        authenticator: PeerAuthenticating = SystemPeerAuthenticator()
    ) {
        self.socketPath = socketPath
        self.configuration = configuration
        self.logger = logger
        self.authenticator = authenticator
    }

    deinit {
        setOwnershipMonitorRunning(false)
        if listener >= 0 {
            Darwin.close(listener)
        }
        unlink(socketPath)
    }

    public func run(runtime: HelperRuntime) throws {
        try bind()
        startSocketOwnershipMonitor()
        logger.info("main", "VEXPrivilegedHelper started on \(socketPath)")
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                throw HelperError.socketAcceptFailed(String(cString: strerror(errno)))
            }
            Task.detached(priority: .userInitiated) { [configuration, logger, authenticator] in
                defer { Darwin.close(client) }
                do {
                    guard let peer = peerCredentials(for: client),
                          authenticator.authenticate(peer) else {
                        throw HelperError.ownerVerificationFailed("unauthenticated helper client")
                    }
                    setSocketTimeout(client, seconds: Int(configuration.commandTimeout))
                    let bytes = try readCommandBytes(from: client, maxBytes: configuration.maxCommandBytes)
                    guard let command = try HelperCommandFrame.decode(bytes, maxBytes: configuration.maxCommandBytes) else {
                        return
                    }
                    if command == "shutdown" {
                        // Acknowledge immediately so application termination is
                        // instant. The signed helper remains alive until the
                        // fail-open teardown has actually completed.
                        try writeResponse("ok\n", to: client)
                        let response = await runtime.handle(commandLine: command, peerPID: peer.pid)
                        if response.shouldExit {
                            logger.info("socket", "shutdown cleanup completed, exiting helper")
                            exit(0)
                        }
                        logger.warn("socket", "shutdown cleanup deferred to owner watchdog")
                        return
                    }
                    let response = await runtime.handle(commandLine: command, peerPID: peer.pid)
                    if response.shouldExit {
                        _ = try? writeResponse(response.payload, to: client)
                        logger.info("socket", "shutdown requested, exiting helper")
                        exit(0)
                    }
                    try writeResponse(response.payload, to: client)
                } catch let error as HelperError {
                    _ = try? writeResponse(error.socketMessage, to: client)
                } catch {
                    _ = try? writeResponse(HelperError.io(error.localizedDescription).socketMessage, to: client)
                }
            }
        }
    }

    private func bind() throws {
        unlink(socketPath)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HelperError.socketCreateFailed }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxLength else {
            throw HelperError.invalidSocketPath
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, maxLength)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, SOMAXCONN) == 0 else {
            throw HelperError.socketBindFailed(String(cString: strerror(errno)))
        }
        updateSocketOwner()
    }

    private func startSocketOwnershipMonitor() {
        guard setOwnershipMonitorRunningIfStopped() else { return }
        Thread.detachNewThread { [weak self] in
            while let self, self.isOwnershipMonitorRunning {
                self.updateSocketOwner()
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private var isOwnershipMonitorRunning: Bool {
        ownershipMonitorLock.withLock { ownershipMonitorRunning }
    }

    private func setOwnershipMonitorRunning(_ running: Bool) {
        ownershipMonitorLock.withLock { ownershipMonitorRunning = running }
    }

    private func setOwnershipMonitorRunningIfStopped() -> Bool {
        ownershipMonitorLock.withLock {
            guard !ownershipMonitorRunning else { return false }
            ownershipMonitorRunning = true
            return true
        }
    }

    private func updateSocketOwner() {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              consoleUser != "loginwindow",
              consoleUser != "_windowserver",
              uid > 0 else {
            _ = chown(socketPath, 0, 0)
            _ = chmod(socketPath, 0o600)
            return
        }
        _ = chown(socketPath, uid, gid)
        _ = chmod(socketPath, 0o600)
    }
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

private func readCommandBytes(from fd: Int32, maxBytes: Int) throws -> [UInt8] {
    var bytes = [UInt8]()
    var nextByte: UInt8 = 0
    while bytes.count <= maxBytes {
        let count = Darwin.read(fd, &nextByte, 1)
        if count == 1 {
            bytes.append(nextByte)
            if nextByte == 10 {
                break
            }
            continue
        }
        if count == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        throw HelperError.readFailed(String(cString: strerror(errno)))
    }
    if bytes.count > maxBytes {
        throw HelperError.commandTooLong(limit: maxBytes)
    }
    return bytes
}

private func writeResponse(_ response: String, to fd: Int32) throws {
    let payload = response.hasSuffix("\n") ? response : response + "\n"
    try HelperSocketIO.writeAll(Array(payload.utf8), to: fd)
}

enum HelperSocketIO {
    static func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            let detail = written == 0
                ? "socket closed during write"
                : String(cString: strerror(errno))
            throw HelperError.writeFailed(detail)
        }
    }
}
