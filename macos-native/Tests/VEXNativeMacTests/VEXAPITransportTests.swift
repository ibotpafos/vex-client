import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(VEXNativeMac)
@testable import VEXNativeMac
#else
@testable import VEXAPITransportHarness
#endif

final class VEXAPITransportTests: XCTestCase {
    private let url = URL(string: "https://fixture.invalid/v1/vpn/profile")!

    func testServerCooldownAndRetriesShareOneDeadline() async throws {
        let fixture = Fixture()
        let transport = fixture.transport { call in call == 1 ? 429 : 200 }
        let (_, response) = try await transport.data(for: URLRequest(url: url), timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fixture.delays, [2])
        XCTAssertEqual(fixture.timeouts, [5, 3])
    }

    func testMaintenanceResponseHonorsRetryAfter() async throws {
        let fixture = Fixture()
        let (_, response) = try await fixture.transport { $0 == 1 ? 503 : 200 }
            .data(for: URLRequest(url: url), timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fixture.delays, [2])
    }

    func testCooldownOutsideBudgetPreservesOriginalHTTPResponse() async throws {
        let fixture = Fixture()
        let (_, response) = try await fixture.transport(retryAfter: "60") { _ in 429 }
            .data(for: URLRequest(url: url), timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertTrue(fixture.delays.isEmpty)
    }

    func testPOSTWithIdempotencyKeyIsSingleAttempt() async throws {
        let fixture = Fixture()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("fixture", forHTTPHeaderField: "Idempotency-Key")
        let (_, response) = try await fixture.transport { _ in 503 }.data(for: request, timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(fixture.calls, 1)
    }

    func testPermanentHTTPFailuresNeverRetry() async throws {
        for status in [400, 401, 403, 404, 409, 500] {
            let fixture = Fixture()
            let (_, response) = try await fixture.transport { _ in status }.data(for: URLRequest(url: url), timeout: 5)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(fixture.calls, 1)
        }
    }

    func testAttemptsAreBoundedEvenWithoutServerCooldown() async throws {
        let fixture = Fixture()
        let (_, response) = try await fixture.transport(retryAfter: nil) { _ in 503 }
            .data(for: URLRequest(url: url), timeout: 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(fixture.calls, 3)
        XCTAssertEqual(fixture.delays, [0.6, 1.2])
    }

    func testConnectionLossRetriesWithinRemainingBudget() async throws {
        let fixture = Fixture()
        var transport = fixture.transport { _ in 200 }
        let successful = transport.load
        transport.load = { request in
            if fixture.recordNetworkAttempt() == 1 { throw URLError(.networkConnectionLost) }
            return try await successful(request)
        }
        _ = try await transport.data(for: URLRequest(url: url), timeout: 5)
        XCTAssertEqual(fixture.networkAttempts, 2)
        XCTAssertEqual(fixture.delays, [0.6])
        XCTAssertEqual(fixture.timeouts, [4.4])
    }

    func testTLSFailuresAreNotRetried() async {
        let fixture = Fixture()
        var transport = fixture.transport { _ in 200 }
        transport.load = { _ in
            _ = fixture.recordNetworkAttempt()
            throw URLError(.serverCertificateUntrusted)
        }
        do {
            _ = try await transport.data(for: URLRequest(url: url), timeout: 5)
            XCTFail("expected certificate rejection")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted)
        }
        XCTAssertEqual(fixture.networkAttempts, 1)
    }

    func testAbsoluteDeadlineCancelsStalledTransport() async {
        var transport = VEXAPITransport()
        transport.load = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw URLError(.unknown)
        }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await transport.data(for: URLRequest(url: url), timeout: 0.03)
            XCTFail("expected deadline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testCancellationDoesNotRetry() async {
        var transport = VEXAPITransport()
        transport.load = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw URLError(.unknown)
        }
        let request = URLRequest(url: url)
        let task = Task { try await transport.data(for: request, timeout: 5) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRetryAfterParserSupportsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-10 UTC
        XCTAssertEqual(VEXAPITransport.retryAfter("2", now: now), 2)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(VEXAPITransport.retryAfter(formatter.string(from: now.addingTimeInterval(3)), now: now), 3)
        XCTAssertEqual(VEXAPITransport.retryAfter(formatter.string(from: now.addingTimeInterval(-3)), now: now), 0)
        for value in [nil, "", "-1", "1.5", "invalid"] {
            XCTAssertNil(VEXAPITransport.retryAfter(value, now: now))
        }
    }

    func testAPIErrorPreservesThrottlingAndTimeoutSemantics() {
        let limited = VEXAPIError.http(status: 429, message: "fixture", code: "rate_limited", retryAfter: 60)
        XCTAssertTrue(limited.isRateLimited)
        if case .http(let status, _, let code, let retryAfter) = limited {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(code, "rate_limited")
            XCTAssertEqual(retryAfter, 60)
        } else { XCTFail("lost HTTP metadata") }
        XCTAssertEqual(VEXAPIError.requestTimeout.code, "request_timeout")
        // Normalized API timeouts must not enable the legacy profile fallback,
        // which is not qualified for replacement device/key identities.
        XCTAssertFalse(VEXAPIError.requestTimeout.isTimeout)
        XCTAssertTrue(VEXAPIError.http(status: 401, message: "fixture").isUnauthorized)
        XCTAssertFalse(VEXAPIError.http(status: 401, message: "fixture", code: "maintenance").isUnauthorized)
        XCTAssertFalse(VEXAPIError.http(status: 400, message: "add-peer unavailable", code: "maintenance").isProfileProvisioningUnavailable)
        XCTAssertEqual(VEXAPIError.http(status: 503, message: "fixture").errorDescription, VEXAPIError.technicalWorksMessage)
        XCTAssertTrue(VEXAPIError.isServerUnavailable(VEXAPIError.http(status: 503, message: "fixture")))
    }
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var recordedCalls = 0
    private var recordedNetworkAttempts = 0
    private var recordedDelays: [TimeInterval] = []
    private var recordedTimeouts: [TimeInterval] = []
    var calls: Int { withLock { recordedCalls } }
    var networkAttempts: Int { withLock { recordedNetworkAttempts } }
    var delays: [TimeInterval] { withLock { recordedDelays } }
    var timeouts: [TimeInterval] { withLock { recordedTimeouts } }

    func recordNetworkAttempt() -> Int { withLock { recordedNetworkAttempts += 1; return recordedNetworkAttempts } }
    func transport(retryAfter: String? = "2", status: @escaping @Sendable (Int) -> Int) -> VEXAPITransport {
        VEXAPITransport(load: { request in
            let count = self.withLock {
                self.recordedCalls += 1
                self.recordedTimeouts.append(request.timeoutInterval)
                return self.recordedCalls
            }
            let headers = retryAfter.map { ["Retry-After": $0] }
            let response = HTTPURLResponse(url: request.url!, statusCode: status(count), httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data("{}".utf8), response)
        }, now: { self.withLock { self.clock } }, sleep: { delay in
            self.withLock { self.recordedDelays.append(delay); self.clock += delay }
        })
    }
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
