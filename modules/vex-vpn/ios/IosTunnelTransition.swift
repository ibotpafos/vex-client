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
}

actor IosTunnelTransition<Manager> {
  private let operations: IosTunnelOperations<Manager>
  private(set) var generation: UInt64 = 0
  private var transitionInProgress = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(operations: IosTunnelOperations<Manager>) {
    self.operations = operations
  }

  func connect(config: String) async throws {
    let operation = nextGeneration()
    await acquireTransition()
    defer { releaseTransition() }

    try checkCurrent(operation)
    let manager = try await operations.loadOrCreate()
    try checkCurrent(operation)
    operations.configure(manager, config)
    try await operations.save(manager)
    try checkCurrent(operation)
    try await operations.reload(manager)
    try checkCurrent(operation)
    // This check and synchronous start share one actor turn; a later operation
    // cannot invalidate the generation between them.
    try operations.start(manager)
  }

  func disconnect() async throws {
    // Invalidate a pending connect before waiting for its preference writes.
    let operation = nextGeneration()
    await acquireTransition()
    defer { releaseTransition() }

    try checkCurrent(operation)
    let manager = try await operations.loadExisting()
    try checkCurrent(operation)
    if let manager {
      operations.stop(manager)
    }
  }

  private func nextGeneration() -> UInt64 {
    generation &+= 1
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
