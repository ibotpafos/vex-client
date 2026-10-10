import Foundation
import XCTest
@testable import IosTunnelTransitionHarness

final class IosTunnelRestartTests: XCTestCase {
  func testChangedProfileStopsOldProviderBeforeStartingReplacement() async throws {
    let system = RestartSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-B") }
    try await waitForStop(in: system)
    XCTAssertEqual(system.activeConfig, "account-A")
    XCTAssertEqual(system.events, ["save:account-B", "stop:account-A"])
    system.finishStop()
    try await connect.value
    XCTAssertEqual(system.events, ["save:account-B", "stop:account-A", "start:account-B"])
    XCTAssertEqual(system.activeConfig, "account-B")
  }

  func testLogoutDuringRestartWaitCancelsOldStartAndReleasesPreferencesQueue() async throws {
    let system = RestartSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let connect = Task { try await transition.connect(config: "account-B") }
    try await waitForStop(in: system)
    try await transition.disconnect()
    do {
      try await connect.value
      XCTFail("Logout must supersede the profile restart")
    } catch is CancellationError {}
    XCTAssertFalse(system.events.contains(where: { $0.hasPrefix("start:") }))
    system.finishStop()
    XCTAssertNil(system.activeConfig)
  }

  func testStopTimeoutNeverStartsNewProfileAndReleasesQueue() async throws {
    let system = RestartSystem()
    system.timeout = 0.02
    let transition = IosTunnelTransition(operations: system.operations)
    do {
      try await transition.connect(config: "account-B")
      XCTFail("A provider that did not stop must not accept a second start")
    } catch is IosTunnelStopTimeout {}
    XCTAssertFalse(system.events.contains(where: { $0.hasPrefix("start:") }))
    try await transition.disconnect()
    system.finishStop()
    XCTAssertNil(system.activeConfig)
  }

  func testNewerConnectCancelsOldRestartWaitAndStartsOnlyLatestProfile() async throws {
    let system = RestartSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let oldConnect = Task { try await transition.connect(config: "account-B") }
    try await waitForStop(in: system)
    let latestConnect = Task { try await transition.connect(config: "account-C") }
    let deadline = Date().addingTimeInterval(5)
    while !system.events.contains("save:account-C") {
      guard Date() < deadline else { system.finishStop(); throw IosTunnelStopTimeout() }
      await Task.yield()
    }
    system.finishStop()
    do {
      try await oldConnect.value
      XCTFail("The newer profile must supersede the old restart")
    } catch is CancellationError {}
    try await latestConnect.value
    XCTAssertEqual(system.activeConfig, "account-C")
    XCTAssertEqual(system.events.filter { $0.hasPrefix("start:") }, ["start:account-C"])
  }

  func testAlreadyInactiveProviderDoesNotWaitOrStop() async throws {
    let system = RestartSystem()
    system.finishStop()
    let transition = IosTunnelTransition(operations: system.operations)
    try await transition.connect(config: "account-B")
    XCTAssertEqual(system.events, ["save:account-B", "start:account-B"])
  }

  private func waitForStop(in system: RestartSystem) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !system.events.contains(where: { $0.hasPrefix("stop:") }) {
      guard Date() < deadline else { throw IosTunnelStopTimeout() }
      await Task.yield()
    }
  }
}

private final class RestartManager { var config = "account-A" }

private final class RestartSystem: @unchecked Sendable {
  private let lock = NSLock()
  private let manager = RestartManager()
  private var active: String? = "account-A"
  private var recordedEvents: [String] = []
  var timeout: TimeInterval = 5

  var events: [String] { locked { recordedEvents } }
  var activeConfig: String? { locked { active } }
  func finishStop() { locked { active = nil } }

  var operations: IosTunnelOperations<RestartManager> {
    IosTunnelOperations(
      loadOrCreate: { self.manager }, loadExisting: { self.manager },
      configure: { manager, config in self.locked { manager.config = config } },
      save: { manager in self.locked { self.recordedEvents.append("save:\(manager.config)") } },
      reload: { _ in },
      start: { manager in
        self.locked {
          // A running provider keeps its existing config until stopped, even
          // if a new start request was accepted by NetworkExtension.
          guard self.active == nil else { return }
          self.recordedEvents.append("start:\(manager.config)")
          self.active = manager.config
        }
      },
      stop: { _ in self.locked { self.recordedEvents.append("stop:\(self.active ?? "inactive")") } },
      needsRestart: { _ in self.activeConfig != nil },
      waitUntilStopped: { _ in
        try await IosTunnelStoppedStatusWait.wait(timeout: self.timeout) { self.activeConfig == nil }
      }
    )
  }

  private func locked<T>(_ action: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return action()
  }
}
