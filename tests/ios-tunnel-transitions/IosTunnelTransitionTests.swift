import Foundation
import XCTest
@testable import IosTunnelTransitionHarness

final class IosTunnelTransitionTests: XCTestCase {
  func testDisconnectInvalidatesConnectWaitingForManager() async throws {
    let system = FakeTunnelSystem(storedConfig: "existing")
    let gate = system.pause(.load)
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let disconnect = Task { try await transition.disconnect() }
    try await waitForRequest(2, in: transition)
    await gate.open()

    await assertCancelled(connect)
    try await disconnect.value
    XCTAssertEqual(system.events, ["load", "load-existing", "stop:existing"])
    XCTAssertNil(system.activeConfig)
  }

  func testLogoutWaitsForOldSaveAndNeverStartsOldAccount() async throws {
    let system = FakeTunnelSystem(storedConfig: "existing")
    let gate = system.pause(.save)
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let disconnect = Task { try await transition.disconnect() }
    try await waitForRequest(2, in: transition)
    XCTAssertEqual(system.events, ["load", "configure:account-A", "save-begin:account-A"])
    await gate.open()

    await assertCancelled(connect)
    try await disconnect.value
    XCTAssertEqual(system.storedConfig, "account-A")
    XCTAssertEqual(system.events.suffix(3), ["save-end:account-A", "load-existing", "stop:account-A"])
    XCTAssertNil(system.activeConfig)
    XCTAssertEqual(system.starts, [])
  }

  func testDisconnectInvalidatesConnectWaitingForReload() async throws {
    let system = FakeTunnelSystem()
    let gate = system.pause(.reload)
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let disconnect = Task { try await transition.disconnect() }
    try await waitForRequest(2, in: transition)
    await gate.open()

    await assertCancelled(connect)
    try await disconnect.value
    XCTAssertEqual(system.starts, [])
    XCTAssertNil(system.activeConfig)
    XCTAssertEqual(system.events.suffix(2), ["load-existing", "stop:account-A"])
  }

  func testNewAccountSaveCannotBeOverwrittenByOlderPendingSave() async throws {
    let system = FakeTunnelSystem()
    let gate = system.pause(.save)
    let transition = IosTunnelTransition(operations: system.operations)
    let oldConnect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let newConnect = Task { try await transition.connect(config: "account-B") }
    try await waitForRequest(2, in: transition)
    XCTAssertEqual(system.concurrentSaves, 1)
    XCTAssertFalse(system.events.contains("configure:account-B"))
    await gate.open()

    await assertCancelled(oldConnect)
    try await newConnect.value
    XCTAssertEqual(system.maximumConcurrentSaves, 1)
    XCTAssertEqual(system.storedConfig, "account-B")
    XCTAssertEqual(system.activeConfig, "account-B")
    XCTAssertEqual(system.starts, ["account-B"])
    XCTAssertLessThan(try XCTUnwrap(system.events.firstIndex(of: "save-end:account-A")),
                      try XCTUnwrap(system.events.firstIndex(of: "save-begin:account-B")))
  }

  func testQueuedLogoutDoesNotStopNewerAccount() async throws {
    let system = FakeTunnelSystem()
    let gate = system.pause(.save)
    let transition = IosTunnelTransition(operations: system.operations)
    let oldConnect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let disconnect = Task { try await transition.disconnect() }
    try await waitForRequest(2, in: transition)
    let newConnect = Task { try await transition.connect(config: "account-B") }
    try await waitForRequest(3, in: transition)
    await gate.open()

    await assertCancelled(oldConnect)
    await assertCancelled(disconnect)
    try await newConnect.value
    XCTAssertFalse(system.events.contains(where: { $0.hasPrefix("stop:") }))
    XCTAssertEqual(system.activeConfig, "account-B")
    XCTAssertEqual(system.storedConfig, "account-B")
  }

  func testInFlightDisconnectDoesNotStopNewerConnect() async throws {
    let system = FakeTunnelSystem(storedConfig: "account-A")
    let gate = system.pause(.loadExisting)
    let transition = IosTunnelTransition(operations: system.operations)
    let disconnect = Task { try await transition.disconnect() }
    await gate.waitUntilEntered()
    let connect = Task { try await transition.connect(config: "account-B") }
    try await waitForRequest(2, in: transition)
    await gate.open()

    await assertCancelled(disconnect)
    try await connect.value
    XCTAssertFalse(system.events.contains(where: { $0.hasPrefix("stop:") }))
    XCTAssertEqual(system.activeConfig, "account-B")
  }

  func testFailedSaveReleasesQueueForLatestConnect() async throws {
    let system = FakeTunnelSystem()
    let gate = system.pause(.save)
    system.failFirstSave = true
    let transition = IosTunnelTransition(operations: system.operations)
    let oldConnect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    let newConnect = Task { try await transition.connect(config: "account-B") }
    try await waitForRequest(2, in: transition)
    await gate.open()

    do {
      try await oldConnect.value
      XCTFail("The failed save must be reported")
    } catch FakeTunnelError.saveFailed {
    }
    try await newConnect.value
    XCTAssertEqual(system.activeConfig, "account-B")
    XCTAssertEqual(system.storedConfig, "account-B")
    XCTAssertEqual(system.maximumConcurrentSaves, 1)
  }

  func testCancelledConnectCannotStartAfterPreferencesResume() async throws {
    let system = FakeTunnelSystem()
    let gate = system.pause(.reload)
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-A") }
    await gate.waitUntilEntered()
    connect.cancel()
    await gate.open()
    await assertCancelled(connect)
    try await transition.connect(config: "account-B")
    XCTAssertEqual(system.starts, ["account-B"])
  }

  func testSequentialConnectAndDisconnectPreserveNormalBehavior() async throws {
    let system = FakeTunnelSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    try await transition.connect(config: "account-A")
    XCTAssertEqual(system.activeConfig, "account-A")
    try await transition.disconnect()
    XCTAssertNil(system.activeConfig)
    XCTAssertEqual(system.events, ["load", "configure:account-A", "save-begin:account-A",
                                   "save-end:account-A", "reload:account-A", "start:account-A",
                                   "load-existing", "stop:account-A"])
  }

  private func waitForRequest(_ generation: UInt64, in transition: IosTunnelTransition<FakeManager>) async throws {
    let deadline = Date().addingTimeInterval(5)
    while await transition.generation < generation {
      guard Date() < deadline else { throw FakeTunnelError.requestTimedOut }
      await Task.yield()
    }
  }

  private func assertCancelled(_ operation: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      try await operation.value
      XCTFail("The superseded operation must be cancelled", file: file, line: line)
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private enum FakeTunnelError: Error {
  case saveFailed
  case requestTimedOut
}

private final class FakeManager {
  var config: String?
  init(config: String?) { self.config = config }
}

private actor PreferenceGate {
  private var entered = false
  private var released = false
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func pause() async {
    entered = true
    entryWaiter?.resume()
    entryWaiter = nil
    if !released {
      await withCheckedContinuation { releaseWaiter = $0 }
    }
  }

  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { entryWaiter = $0 } }
  }

  func open() {
    released = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

private final class FakeTunnelSystem: @unchecked Sendable {
  enum Stage { case load, loadExisting, save, reload }
  private let lock = NSLock()
  private var gates: [Stage: PreferenceGate] = [:]
  private var recordedEvents: [String] = []
  private var preferenceConfig: String?
  private var connectionConfig: String?
  private var recordedStarts: [String] = []
  private var activeSaves = 0
  private var maxActiveSaves = 0
  var failFirstSave = false

  init(storedConfig: String? = nil) {
    preferenceConfig = storedConfig
    connectionConfig = storedConfig
  }

  var events: [String] { locked { recordedEvents } }
  var storedConfig: String? { locked { preferenceConfig } }
  var activeConfig: String? { locked { connectionConfig } }
  var starts: [String] { locked { recordedStarts } }
  var concurrentSaves: Int { locked { activeSaves } }
  var maximumConcurrentSaves: Int { locked { maxActiveSaves } }

  func pause(_ stage: Stage) -> PreferenceGate {
    let gate = PreferenceGate()
    locked { gates[stage] = gate }
    return gate
  }

  var operations: IosTunnelOperations<FakeManager> {
    IosTunnelOperations(
      loadOrCreate: { [self] in
        let manager = locked { recordedEvents.append("load"); return FakeManager(config: preferenceConfig) }
        await takeGate(.load)?.pause()
        return manager
      },
      loadExisting: { [self] in
        let manager = locked { () -> FakeManager? in
          recordedEvents.append("load-existing")
          return preferenceConfig.map { FakeManager(config: $0) }
        }
        await takeGate(.loadExisting)?.pause()
        return manager
      },
      configure: { [self] manager, config in
        locked { recordedEvents.append("configure:\(config)"); manager.config = config }
      },
      save: { [self] manager in
        let config = manager.config ?? ""
        locked {
          activeSaves += 1
          maxActiveSaves = max(maxActiveSaves, activeSaves)
          recordedEvents.append("save-begin:\(config)")
        }
        await takeGate(.save)?.pause()
        let failed = locked { () -> Bool in
          activeSaves -= 1
          if failFirstSave {
            failFirstSave = false
            recordedEvents.append("save-failed:\(config)")
            return true
          }
          preferenceConfig = config
          recordedEvents.append("save-end:\(config)")
          return false
        }
        if failed { throw FakeTunnelError.saveFailed }
      },
      reload: { [self] manager in
        locked { recordedEvents.append("reload:\(manager.config ?? "")") }
        await takeGate(.reload)?.pause()
        locked { manager.config = preferenceConfig }
      },
      start: { [self] manager in
        locked {
          let config = manager.config ?? ""
          recordedEvents.append("start:\(config)")
          recordedStarts.append(config)
          connectionConfig = config
        }
      },
      stop: { [self] manager in
        locked { recordedEvents.append("stop:\(manager.config ?? "")"); connectionConfig = nil }
      }
    )
  }

  private func takeGate(_ stage: Stage) -> PreferenceGate? { locked { gates.removeValue(forKey: stage) } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
