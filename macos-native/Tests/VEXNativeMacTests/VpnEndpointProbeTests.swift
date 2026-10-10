import XCTest
@testable import VEXNativeMac

final class VpnEndpointProbeTests: XCTestCase {
    func testWaitingConnectionReturnsAtDeadlineAndCancelsOnce() async {
        let connection = ProbeFixture()
        let completed = expectation(description: "deadline releases waiting connection")
        let task = Task {
            let result = await VpnEndpointProbe.run(timeout: .milliseconds(30), start: connection.start)
            connection.record(result)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        task.cancel()
        XCTAssertEqual(connection.result?.endpointProbeError, "endpoint probe timed out")
        XCTAssertEqual(connection.cancellationCount, 1)
    }

    func testCallerCancellationReleasesWaitingConnection() async {
        let connection = ProbeFixture()
        let started = expectation(description: "connection started")
        let completed = expectation(description: "caller cancellation returns")
        let task = Task {
            let result = await VpnEndpointProbe.run(timeout: .seconds(30)) { finish in
                let cancel = connection.start(finish)
                started.fulfill()
                return cancel
            }
            connection.record(result)
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(connection.result, .empty)
        XCTAssertEqual(connection.cancellationCount, 1)
        connection.complete(VpnAutopilotProbeResult(dnsOk: false, endpointProbeError: "late DNS failure"))
        XCTAssertEqual(connection.result, .empty)
        XCTAssertEqual(connection.cancellationCount, 1)
    }

    func testAlreadyCancelledCallerDoesNotStartConnection() async {
        let connection = ProbeFixture()
        let gate = ProbeGate()
        let task = Task {
            await gate.wait()
            return await VpnEndpointProbe.run(start: connection.start)
        }
        task.cancel()
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(connection.startCount, 0)
        XCTAssertEqual(connection.cancellationCount, 0)
    }

    func testSynchronousReadyPreservesResultAndCancelsRegisteredConnection() async {
        let connection = ProbeFixture()
        let ready = VpnAutopilotProbeResult(dnsOk: true, endpointLatencyMs: 12)
        let result = await VpnEndpointProbe.run(timeout: .seconds(30)) { finish in
            let cancel = connection.start(finish)
            finish(ready)
            return cancel
        }
        XCTAssertEqual(result, ready)
        XCTAssertEqual(connection.cancellationCount, 1)
        connection.complete(VpnAutopilotProbeResult(dnsOk: false))
        XCTAssertEqual(connection.cancellationCount, 1)
    }

    func testCancellationBeforeConnectionRegistrationStillCancelsOnce() async {
        let connection = ProbeFixture()
        let started = expectation(description: "start callback entered")
        let completed = expectation(description: "cancellation returns after registration")
        let registration = DispatchSemaphore(value: 0)
        let task = Task {
            let result = await VpnEndpointProbe.run(timeout: .seconds(30)) { finish in
                let cancel = connection.start(finish)
                started.fulfill()
                _ = registration.wait(timeout: .now() + 1)
                return cancel
            }
            connection.record(result)
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        registration.signal()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(connection.result, .empty)
        XCTAssertEqual(connection.cancellationCount, 1)
    }

    func testConnectionFailureIsPreservedAndWinsOnlyOnce() async {
        let connection = ProbeFixture()
        let failed = VpnAutopilotProbeResult(dnsOk: false, endpointProbeError: "DNS unavailable")
        let result = await VpnEndpointProbe.run(timeout: .seconds(30)) { finish in
            let cancel = connection.start(finish)
            finish(failed)
            finish(VpnAutopilotProbeResult(dnsOk: true))
            return cancel
        }
        XCTAssertEqual(result, failed)
        XCTAssertEqual(connection.cancellationCount, 1)
    }
}

private final class ProbeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: VpnEndpointProbe.Finish?
    private var recordedResult: VpnAutopilotProbeResult?
    private var starts = 0
    private var cancellations = 0

    var result: VpnAutopilotProbeResult? { withLock { recordedResult } }
    var startCount: Int { withLock { starts } }
    var cancellationCount: Int { withLock { cancellations } }

    func start(_ finish: @escaping VpnEndpointProbe.Finish) -> VpnEndpointProbe.Cancel {
        withLock { starts += 1; self.finish = finish }
        return { self.withLock { self.cancellations += 1 } }
    }

    func complete(_ result: VpnAutopilotProbeResult) {
        let finish = withLock { self.finish }
        finish?(result)
    }

    func record(_ result: VpnAutopilotProbeResult) {
        withLock { recordedResult = result }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor ProbeGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
