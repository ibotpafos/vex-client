import Foundation
import XCTest
@testable import IosTunnelTransitionHarness

final class IosTunnelRuntimeStatusTests: XCTestCase {
  private let healthy = Data("private_key=do-not-export\npublic_key=peer\npreshared_key=do-not-export\nrx_bytes=128\ntx_bytes=64\nlast_handshake_time_sec=1700000000\nlast_handshake_time_nsec=500000000\nerrno=0\n".utf8)

  func testHealthyProviderResponseVerifiesTunnelAndReturnsRealCounters() async throws {
    let system = StatusSystem()
    system.immediateReply = healthy
    let transition = IosTunnelTransition(operations: system.operations)

    let status = await transition.currentStatus(using: system.statusOperations)

    XCTAssertEqual(status.state, "connected")
    XCTAssertTrue(status.verified)
    XCTAssertEqual(status.rxBytes, 128)
    XCTAssertEqual(status.txBytes, 64)
    XCTAssertEqual(status.latestHandshakeEpochMillis, 1_700_000_000_500)
    XCTAssertEqual(Set(status.toDictionary().keys), ["state", "nativeState", "rxBytes", "txBytes", "verified", "latestHandshakeEpochMillis"])
    XCTAssertFalse(String(describing: status.toDictionary()).contains("do-not-export"))
  }

  func testConcurrentPollsShareOnePreferencesAndProviderRequest() async throws {
    let system = StatusSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    async let first = transition.currentStatus(using: system.statusOperations)
    async let second = transition.currentStatus(using: system.statusOperations)
    try await waitForRequest(in: system)
    for _ in 0..<100 { await Task.yield() }
    system.reply(healthy)
    let results = await [first, second]
    XCTAssertEqual(system.requestCount, 1)
    XCTAssertEqual(system.loadCount, 1)
    XCTAssertTrue(results.allSatisfy(\.verified))
  }

  func testMissingPreferencesCannotMasqueradeAsDisconnectedOnLoadFailure() async {
    let system = StatusSystem()
    system.failLoad = true
    let transition = IosTunnelTransition(operations: system.operations)
    let status = await transition.currentStatus(using: system.statusOperations)
    XCTAssertEqual(status.state, "error")
    XCTAssertEqual(system.requestCount, 0)
  }

  func testKnownConnectionStillProvidesStatusAfterPreferenceFailure() async throws {
    let system = StatusSystem()
    system.immediateReply = healthy
    let transition = IosTunnelTransition(operations: system.operations)
    try await transition.connect(config: "account-A")
    system.failLoad = true
    let status = await transition.currentStatus(using: system.statusOperations)
    XCTAssertEqual(status.state, "connected")
    XCTAssertTrue(status.verified)
  }

  func testLogoutAndNewConnectDiscardOldProviderMetrics() async throws {
    let system = StatusSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let oldStatus = Task { await transition.currentStatus(using: system.statusOperations) }
    try await waitForRequest(in: system)
    try await transition.disconnect()
    try await transition.connect(config: "account-B")
    system.reply(healthy)
    let result = await oldStatus.value
    XCTAssertFalse(result.verified)
    XCTAssertEqual(result.rxBytes, 0)
    XCTAssertNil(result.latestHandshakeEpochMillis)
  }

  func testExternalDisconnectWhileWaitingForProviderClearsMetrics() async throws {
    let system = StatusSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let pending = Task { await transition.currentStatus(using: system.statusOperations) }
    try await waitForRequest(in: system)
    system.externalDisconnect()
    system.reply(healthy)
    let result = await pending.value
    XCTAssertEqual(result.state, "disconnected")
    XCTAssertEqual(result.rxBytes, 0)
    XCTAssertFalse(result.verified)
  }

  func testProviderRestartCannotReusePreviousConnectionHandshake() async throws {
    let system = StatusSystem()
    let transition = IosTunnelTransition(operations: system.operations)
    let pending = Task { await transition.currentStatus(using: system.statusOperations) }
    try await waitForRequest(in: system)
    system.externalRestart()
    system.reply(healthy)
    let result = await pending.value
    XCTAssertEqual(result.state, "connected")
    XCTAssertFalse(result.verified)
    XCTAssertEqual(result.rxBytes, 0)
    XCTAssertNil(result.latestHandshakeEpochMillis)
  }

  func testSilentProviderTimesOutAndLateDuplicateRepliesAreIgnored() async throws {
    let system = StatusSystem()
    let start = Date()
    let result = await IosTunnelStatusRequest.read(timeout: 0.02) { reply in
      try system.statusOperations.requestRuntime(system.manager, reply)
    }
    XCTAssertNil(result)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    system.reply(healthy)
    system.reply(healthy)
  }

  func testCancellationCompletesProviderRequestWithoutWaitingForTimeout() async throws {
    let system = StatusSystem()
    let pending = Task {
      await IosTunnelStatusRequest.read(timeout: 10) { reply in
        try system.statusOperations.requestRuntime(system.manager, reply)
      }
    }
    try await waitForRequest(in: system)
    pending.cancel()
    let result = await pending.value
    XCTAssertNil(result)
    system.reply(healthy)
  }

  func testAlreadyCancelledProviderRequestNeverSendsOrWaitsForTimeout() async {
    let system = StatusSystem()
    let pending = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await IosTunnelStatusRequest.read(timeout: 10) { reply in
        try system.statusOperations.requestRuntime(system.manager, reply)
      }
    }
    let result = await pending.value
    XCTAssertNil(result)
    XCTAssertEqual(system.requestCount, 0)
  }

  func testThrowingProviderRequestCompletesWithoutWaitingForTimeout() async {
    let start = Date()
    let result = await IosTunnelStatusRequest.read(timeout: 10) { _ in throw StatusError.load }
    XCTAssertNil(result)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testRuntimeParserAggregatesPeersAndUsesLatestHandshake() throws {
    let data = Data("rx_bytes=999\npublic_key=first\nrx_bytes=10\ntx_bytes=20\nlast_handshake_time_sec=100\nlast_handshake_time_nsec=900000000\npublic_key=second\nrx_bytes=30\ntx_bytes=40\nlast_handshake_time_sec=101\nlast_handshake_time_nsec=500000000\nerrno=0\n".utf8)
    let result = try XCTUnwrap(IosTunnelRuntimeStatus(data: data))
    XCTAssertEqual(result.rxBytes, 40)
    XCTAssertEqual(result.txBytes, 60)
    XCTAssertEqual(result.latestHandshakeEpochMillis, 101_500)
  }

  func testInvalidAndPendingRuntimeCannotVerifyTunnel() throws {
    XCTAssertNil(IosTunnelRuntimeStatus(data: Data([0xff])))
    XCTAssertNil(IosTunnelRuntimeStatus(data: Data("public_key=p\nlast_handshake_time_sec=100\nerrno=5\n".utf8)))
    let result = try XCTUnwrap(IosTunnelRuntimeStatus(data: Data("public_key=p\nrx_bytes=0\ntx_bytes=0\nlast_handshake_time_sec=0\nerrno=0\n".utf8)))
    XCTAssertEqual(result.rxBytes, 0)
    XCTAssertEqual(result.txBytes, 0)
    XCTAssertNil(result.latestHandshakeEpochMillis)
  }

  func testActualAppleRawResponseWithoutErrnoVerifiesTunnel() async throws {
    let system = StatusSystem()
    // WireGuardAdapter.getRuntimeConfiguration -> wgGetConfig -> IpcGet
    // returns this raw format; only IpcHandle adds an errno trailer.
    let publicKey = String(repeating: "ab", count: 32)
    system.immediateReply = Data("private_key=never-export\nlisten_port=51820\npublic_key=\(publicKey)\npreshared_key=never-export\nprotocol_version=1\nendpoint=192.0.2.1:51820\nlast_handshake_time_sec=1700000000\nlast_handshake_time_nsec=123000000\ntx_bytes=20\nrx_bytes=10\npersistent_keepalive_interval=25\nallowed_ip=0.0.0.0/0\n".utf8)
    let transition = IosTunnelTransition(operations: system.operations)
    let status = await transition.currentStatus(using: system.statusOperations)
    XCTAssertTrue(status.verified)
    XCTAssertEqual(status.rxBytes, 10)
    XCTAssertEqual(status.txBytes, 20)
    XCTAssertEqual(status.latestHandshakeEpochMillis, 1_700_000_000_123)
    XCTAssertFalse(String(describing: status.toDictionary()).contains("never-export"))
    XCTAssertFalse(String(describing: status.toDictionary()).contains(publicKey))
  }

  func testMalformedAndIncompleteRuntimeCannotVerifyHandshake() throws {
    func peer(rx: String = "10", tx: String = "20", seconds: String = "1700000000", nanos: String = "123000000") -> String {
      "public_key=synthetic\nrx_bytes=\(rx)\ntx_bytes=\(tx)\nlast_handshake_time_sec=\(seconds)\nlast_handshake_time_nsec=\(nanos)\n"
    }
    for text in [
      "", "private_key=never-export\n", peer(rx: "-1"), peer(tx: "NaN"),
      peer(seconds: "18446744073709551615"), peer(nanos: "1000000000"),
      peer() + "rx_bytes=1\n", peer() + "errno=5\n", peer() + "truncated-line",
      peer().replacingOccurrences(of: "tx_bytes=20\n", with: ""),
      peer(rx: "9007199254740991") + peer(rx: "1"),
      String(repeating: "x", count: 128 * 1024 + 1),
    ] {
      XCTAssertNil(IosTunnelRuntimeStatus(data: Data(text.utf8)))
    }
    let secondResolution = peer().replacingOccurrences(of: "last_handshake_time_nsec=123000000\n", with: "")
    XCTAssertEqual(IosTunnelRuntimeStatus(data: Data(secondResolution.utf8))?.latestHandshakeEpochMillis, 1_700_000_000_000)
  }

  func testRuntimeRejectsCountersOutsideExactJavaScriptIntegerRange() {
    XCTAssertNil(IosTunnelRuntimeStatus(data: Data("public_key=p\nrx_bytes=18446744073709551615\ntx_bytes=18446744073709551615\nlast_handshake_time_sec=18446744073709551615\nlast_handshake_time_nsec=1000000000\nerrno=0\n".utf8)))
    XCTAssertEqual(IosTunnelRuntimeStatus(data: Data("public_key=p\nrx_bytes=9007199254740991\ntx_bytes=0\nlast_handshake_time_sec=1\n".utf8))?.rxBytes, 9_007_199_254_740_991)
  }

  private func waitForRequest(in system: StatusSystem) async throws {
    let deadline = Date().addingTimeInterval(5)
    while system.requestCount == 0 {
      guard Date() < deadline else { throw StatusError.timeout }
      await Task.yield()
    }
  }
}

private enum StatusError: Error { case load, timeout }
private final class StatusManager {}

private final class StatusSystem: @unchecked Sendable {
  let manager = StatusManager()
  private let lock = NSLock()
  private var active = true
  private var connectedAt = Date(timeIntervalSince1970: 1)
  private var loads = 0
  private var replies: [(Data?) -> Void] = []
  var failLoad = false
  var immediateReply: Data?

  var requestCount: Int { locked { replies.count } }
  var loadCount: Int { locked { loads } }

  var operations: IosTunnelOperations<StatusManager> {
    IosTunnelOperations(
      loadOrCreate: { self.manager },
      loadExisting: {
        let failed = self.locked { self.loads += 1; return self.failLoad }
        if failed { throw StatusError.load }
        return self.manager
      },
      configure: { _, _ in }, save: { _ in }, reload: { _ in },
      start: { _ in self.externalRestart() }, stop: { _ in self.externalDisconnect() }
    )
  }

  var statusOperations: IosTunnelStatusOperations<StatusManager> {
    IosTunnelStatusOperations(readState: { _ in
      self.locked {
        IosTunnelStatusSnapshot(state: self.active ? "connected" : "disconnected", nativeState: self.active ? 3 : 1, connectedAt: self.active ? self.connectedAt : nil)
      }
    }, requestRuntime: { _, reply in
      let immediate = self.locked { self.replies.append(reply); return self.immediateReply }
      if let immediate { reply(immediate) }
    }, timeout: 1)
  }

  func reply(_ data: Data?) { locked { replies.first }?(data) }
  func externalDisconnect() { locked { active = false } }
  func externalRestart() { locked { active = true; connectedAt = connectedAt.addingTimeInterval(1) } }

  private func locked<T>(_ action: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return action()
  }
}
