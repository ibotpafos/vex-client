import Foundation

private enum FixtureError: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw FixtureError.failed(message) }
}

private final class Manager {}
private final class Fixture {
  let manager = Manager()
  var preferenceFailure = false
  var suspendFailure = false
  var suspended = 0
  var stopped = 0
  var started = 0

  var operations: IosTunnelOperations<Manager> {
    IosTunnelOperations(
      loadOrCreate: { self.manager },
      loadExisting: {
        if self.preferenceFailure { throw FixtureError.failed("preferences unavailable") }
        return self.manager
      },
      configure: { _, _ in },
      save: { _ in },
      reload: { _ in },
      start: { _ in self.started += 1 },
      stop: { _ in self.stopped += 1 },
      suspendTransport: { _ in
        if self.suspendFailure { throw FixtureError.failed("provider did not acknowledge") }
        self.suspended += 1
      }
    )
  }
}

private actor ReadGate {
  private var entered = false
  private var reader: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  func hold() async {
    entered = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { reader = $0 }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { waiter = $0 } }
  }
  func release() { reader?.resume(); reader = nil }
}

@main
private struct RoutingSuspendChecks {
  static func main() async throws {
    let system = Fixture()
    let transition = IosTunnelTransition(operations: system.operations)
    try await transition.connect(config: "fixture")
    system.preferenceFailure = true
    try await transition.suspend()
    try require(system.suspended == 1 && system.stopped == 0, "preference failure released capture or failed to stop known crypto")
    let status = await transition.currentStatus(using: IosTunnelStatusOperations(
      readState: { _ in IosTunnelStatusSnapshot(state: "connected", nativeState: 3, leakProtection: "armed") },
      requestRuntime: { _, reply in reply(Data("vex_transport_stopped=true\n".utf8)) }
    ))
    try require(status.state == "disconnected" && status.leakProtection == "blocking", "retained capture was reported as usable VPN")
    system.suspendFailure = true
    do { try await transition.suspend(); throw FixtureError.failed("missing provider receipt was accepted") }
    catch FixtureError.failed(let reason) where reason == "provider did not acknowledge" {}
    try require(system.stopped == 0, "provider failure stopped the captured tunnel")

    let next = Fixture()
    let gate = ReadGate()
    var operations = next.operations
    operations = IosTunnelOperations(
      loadOrCreate: operations.loadOrCreate,
      loadExisting: { await gate.hold(); return next.manager },
      configure: operations.configure, save: operations.save, reload: operations.reload,
      start: operations.start, stop: operations.stop, suspendTransport: operations.suspendTransport
    )
    let serialized = IosTunnelTransition(operations: operations)
    let suspension = Task { try await serialized.suspend() }
    await gate.waitUntilEntered()
    let replacement = Task { try await serialized.connect(config: "replacement") }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await serialized.generation < 2 {
      try require(ContinuousClock.now < deadline, "replacement did not invalidate pending suspension")
      await Task.yield()
    }
    await gate.release()
    do { try await suspension.value; throw FixtureError.failed("obsolete suspension applied") }
    catch is CancellationError {}
    try await replacement.value
    try require(next.suspended == 0 && next.stopped == 0 && next.started == 1, "stale suspension touched replacement")
    print("PASS iOS protected suspend: preferences failure, provider receipt, retained status and superseding connect")
  }
}
