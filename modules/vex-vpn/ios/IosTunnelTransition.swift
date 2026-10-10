import Foundation

// Keep the preference transaction and activation together. Actor reentrancy
// alone would allow a later save or stop to overtake an awaited preference call.
struct IosTunnelOperations<Manager> {
  let loadOrCreate: () async throws -> Manager
  let loadExisting: () async throws -> Manager?
  let configure: (Manager, String) -> Void
  let save: (Manager) async throws -> Void
  let reload: (Manager) async throws -> Void
  let start: (Manager) throws -> Void
  let stop: (Manager) -> Void
  var needsRestart: (Manager) -> Bool = { _ in false }
  var waitUntilStopped: (Manager) async throws -> Void = { _ in }
}

actor IosTunnelTransition<Manager> {
  private let operations: IosTunnelOperations<Manager>
  private(set) var generation: UInt64 = 0
  private var transitionInProgress = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var knownManager: Manager?
  private var requestedState = "disconnected"
  private var statusFlight: (generation: UInt64, id: UUID, task: Task<IosTunnelStatusSnapshot, Never>)?
  private var stopWaitTask: Task<Void, Error>?

  init(operations: IosTunnelOperations<Manager>) {
    self.operations = operations
  }

  func connect(config: String) async throws {
    try Task.checkCancellation()
    requestedState = "connecting"
    let operation = nextGeneration()
    await acquireTransition()
    defer { releaseTransition() }

    try checkCurrent(operation)
    let manager = try await operations.loadOrCreate()
    try checkCurrent(operation)
    knownManager = manager
    operations.configure(manager, config)
    try await operations.save(manager)
    try checkCurrent(operation)
    try await operations.reload(manager)
    try checkCurrent(operation)
    if operations.needsRestart(manager) {
      // Saving preferences does not update a running provider. Stop and wait
      // for it to become inactive before starting the replacement config.
      operations.stop(manager)
      let wait = Task { try await self.operations.waitUntilStopped(manager) }
      stopWaitTask = wait
      defer { stopWaitTask = nil }
      try await withTaskCancellationHandler {
        try await wait.value
      } onCancel: {
        wait.cancel()
      }
      try checkCurrent(operation)
    }
    // This check and synchronous start share one actor turn; a later operation
    // cannot invalidate the generation between them.
    try operations.start(manager)
  }

  func disconnect() async throws {
    try Task.checkCancellation()
    // Invalidate a pending connect before waiting for its preference writes.
    requestedState = "disconnecting"
    let operation = nextGeneration()
    await acquireTransition()
    defer { releaseTransition() }

    try checkCurrent(operation)
    let manager: Manager?
    do {
      manager = try await operations.loadExisting() ?? knownManager
    } catch {
      // A failed preference read must not prevent logout from stopping the
      // connection we already loaded or started in this process.
      guard let knownManager else { throw error }
      manager = knownManager
    }
    try checkCurrent(operation)
    if let manager {
      knownManager = manager
      operations.stop(manager)
    }
  }

  func currentStatus(using statusOperations: IosTunnelStatusOperations<Manager>) async -> IosTunnelStatusSnapshot {
    if transitionInProgress { return pendingStatus() }
    let operation = generation
    let flight: (generation: UInt64, id: UUID, task: Task<IosTunnelStatusSnapshot, Never>)
    if let current = statusFlight, current.generation == operation {
      flight = current
    } else {
      flight = (operation, UUID(), Task { await self.readStatus(operation, using: statusOperations) })
      statusFlight = flight
    }
    let result = await flight.task.value
    if statusFlight?.id == flight.id { statusFlight = nil }
    guard operation == generation else {
      return transitionInProgress ? pendingStatus() : knownManager.map(statusOperations.readState) ?? .disconnected
    }
    return result
  }

  private func readStatus(_ operation: UInt64, using statusOperations: IosTunnelStatusOperations<Manager>) async -> IosTunnelStatusSnapshot {
    let manager: Manager?
    do {
      manager = try await operations.loadExisting() ?? knownManager
    } catch {
      // Do not turn an unreadable preferences store into a false disconnect.
      guard let knownManager else { return .error }
      manager = knownManager
    }
    guard operation == generation, !Task.isCancelled else { return pendingStatus() }
    if transitionInProgress { return pendingStatus() }
    guard let manager else { return .disconnected }
    knownManager = manager
    var status = statusOperations.readState(manager)
    guard status.state == "connected" else { return status }
    let connectedAt = status.connectedAt
    let data = await IosTunnelStatusRequest.read(timeout: statusOperations.timeout) { reply in
      try statusOperations.requestRuntime(manager, reply)
    }
    guard operation == generation, !Task.isCancelled else { return pendingStatus() }
    if transitionInProgress { return pendingStatus() }
    status = statusOperations.readState(manager)
    guard status.state == "connected", status.connectedAt == connectedAt else { return status }
    if let data, let runtime = IosTunnelRuntimeStatus(data: data) {
      status.rxBytes = runtime.rxBytes
      status.txBytes = runtime.txBytes
      status.latestHandshakeEpochMillis = runtime.latestHandshakeEpochMillis
      status.verified = runtime.latestHandshakeEpochMillis != nil
    }
    return status
  }

  private func pendingStatus() -> IosTunnelStatusSnapshot {
    IosTunnelStatusSnapshot(state: requestedState, nativeState: requestedState == "connecting" ? 2 : 5)
  }

  private func nextGeneration() -> UInt64 {
    generation &+= 1
    statusFlight?.task.cancel()
    statusFlight = nil
    stopWaitTask?.cancel()
    return generation
  }

  private func checkCurrent(_ operation: UInt64) throws {
    try Task.checkCancellation()
    guard operation == generation else {
      throw CancellationError()
    }
  }

  private func acquireTransition() async {
    if transitionInProgress {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      transitionInProgress = true
    }
  }

  private func releaseTransition() {
    if waiters.isEmpty {
      transitionInProgress = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

enum IosTunnelStoppedStatusWait {
  static func wait(timeout: TimeInterval = 5, isStopped: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !isStopped() {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw IosTunnelStopTimeout() }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try Task.checkCancellation()
  }
}

struct IosTunnelStopTimeout: LocalizedError {
  var errorDescription: String? { "The previous iOS tunnel did not stop before reconnecting." }
}

struct IosTunnelStatusOperations<Manager> {
  let readState: (Manager) -> IosTunnelStatusSnapshot
  let requestRuntime: (Manager, @escaping (Data?) -> Void) throws -> Void
  var timeout: TimeInterval = 1
}

struct IosTunnelStatusSnapshot {
  let state: String
  let nativeState: Int
  var connectedAt: Date? = nil
  var rxBytes: Double = 0
  var txBytes: Double = 0
  var latestHandshakeEpochMillis: Double? = nil
  var verified = false

  static var disconnected: Self { Self(state: "disconnected", nativeState: 1) }
  static var error: Self { Self(state: "error", nativeState: 0) }

  func toDictionary() -> [String: Any] {
    var result: [String: Any] = ["state": state, "nativeState": nativeState, "rxBytes": rxBytes, "txBytes": txBytes]
    if state == "connected" {
      result["verified"] = verified
      if let latestHandshakeEpochMillis { result["latestHandshakeEpochMillis"] = latestHandshakeEpochMillis }
      if !verified { result["verificationReason"] = "handshake_pending" }
    }
    return result
  }
}

// The provider response is UAPI, which includes private key material. Extract
// only counters and handshake times; never expose or log the raw response.
struct IosTunnelRuntimeStatus {
  private static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991
  private(set) var rxBytes: Double = 0
  private(set) var txBytes: Double = 0
  private(set) var latestHandshakeEpochMillis: Double? = nil

  init?(data: Data) {
    guard data.count <= 128 * 1024,
          let text = String(data: data, encoding: .utf8) else { return nil }
    let fields: Set<String> = ["rx_bytes", "tx_bytes", "last_handshake_time_sec", "last_handshake_time_nsec"]
    var peer: [String: UInt64]?
    var totalRX: UInt64 = 0
    var totalTX: UInt64 = 0
    var peerCount = 0

    func collectPeer() -> Bool {
      guard let peer, let rx = peer["rx_bytes"], let tx = peer["tx_bytes"],
            let seconds = peer["last_handshake_time_sec"] else { return false }
      let nanoseconds = peer["last_handshake_time_nsec"] ?? 0
      guard nanoseconds < 1_000_000_000, seconds <= Self.maximumSafeInteger / 1000,
            rx <= Self.maximumSafeInteger - totalRX,
            tx <= Self.maximumSafeInteger - totalTX else { return false }
      let timestamp = seconds == 0 ? 0 : seconds * 1000 + nanoseconds / 1_000_000
      guard timestamp <= Self.maximumSafeInteger else { return false }
      totalRX += rx
      totalTX += tx
      peerCount += 1
      if timestamp > 0 {
        latestHandshakeEpochMillis = max(latestHandshakeEpochMillis ?? 0, Double(timestamp))
      }
      return true
    }
    for line in text.split(whereSeparator: \.isNewline) {
      let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { return nil }
      let key = String(pair[0])
      let value = pair[1]
      if key == "public_key" {
        if peer != nil && !collectPeer() { return nil }
        peer = [:]
      } else if fields.contains(key) || key == "errno" {
        // wgGetConfig returns raw IpcGet output, without an errno trailer.
        // Accept that response while rejecting an explicit nonzero IPC error.
        if key != "errno" && peer == nil { continue }
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt64(value), number <= Self.maximumSafeInteger else { return nil }
        if key == "errno" {
          guard number == 0 else { return nil }
        } else {
          guard peer?[key] == nil else { return nil }
          peer?[key] = number
        }
      }
    }
    guard collectPeer(), peerCount > 0 else { return nil }
    rxBytes = Double(totalRX)
    txBytes = Double(totalTX)
  }
}

enum IosTunnelStatusRequest {
  static func read(timeout: TimeInterval, send: (@escaping (Data?) -> Void) throws -> Void) async -> Data? {
    let reply = IosTunnelStatusReply()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard reply.install(continuation) else { return }
        let deadline = DispatchWorkItem { reply.resolve(nil) }
        reply.installDeadline(deadline)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        do { try send { reply.resolve($0) } } catch { reply.resolve(nil) }
      }
    } onCancel: {
      reply.resolve(nil)
    }
  }
}

private final class IosTunnelStatusReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data?, Never>?
  private var deadline: DispatchWorkItem?
  private var resolved = false

  func install(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
    lock.lock()
    if resolved {
      lock.unlock()
      continuation.resume(returning: nil)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func installDeadline(_ deadline: DispatchWorkItem) {
    lock.lock()
    if resolved { deadline.cancel() } else { self.deadline = deadline }
    lock.unlock()
  }

  func resolve(_ data: Data?) {
    lock.lock()
    guard !resolved else { lock.unlock(); return }
    resolved = true
    let continuation = self.continuation
    self.continuation = nil
    let deadline = self.deadline
    self.deadline = nil
    lock.unlock()
    deadline?.cancel()
    continuation?.resume(returning: data)
  }
}
