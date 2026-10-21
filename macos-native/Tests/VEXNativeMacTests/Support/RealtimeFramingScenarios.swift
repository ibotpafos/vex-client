import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !VEX_API_STANDALONE
@testable import VEXNativeMac
#endif

/// Shared by the full API probe, the isolated realtime target and native XCTest.
enum RealtimeFramingScenarios {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }
    @MainActor
    private static func waitUntil(timeout: TimeInterval, _ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "SSE fixture condition timed out")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    static func oversizedRealtimeReconnect(invalidMetadata: Bool) async throws {
        let fixture = APIOversizedRealtimeFixture(invalidMetadata: invalidMetadata)
        APIOversizedRealtimeProtocol.register(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIOversizedRealtimeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); APIOversizedRealtimeProtocol.remove(fixture) }
        var events: [CustomerRealtimeEvent] = []
        var heartbeatAt: TimeInterval?
        let service = CustomerRealtimeService(
            baseURL: URL(string: "https://\(fixture.host)/prefix")!, session: session,
            reconnectSleep: { delay in
                fixture.recordDelay(delay)
                try Task.checkCancellation()
            }
        ) { event, _ in
            events.append(event)
            if event.type == "customer.heartbeat" { heartbeatAt = ProcessInfo.processInfo.systemUptime }
        }
        defer { service.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        service.start(accessToken: "fixture-token")
        do {
            try await waitUntil(timeout: 4) { fixture.firstStoppedAt != nil && heartbeatAt != nil }
        } catch {
            throw Failure("oversized reconnect incomplete: requests=\(fixture.requests.count) stopped=\(fixture.firstStoppedAt != nil) delays=\(fixture.delays) events=\(events.map(\.type))")
        }
        service.stop()
        try require(fixture.firstStoppedAt! <= deadline && heartbeatAt! <= deadline, "oversized reconnect exceeded the existing four-second test bound")
        let requests = fixture.requests
        try require(requests.count == 2, "oversized reconnect request count changed")
        try require(requests.map { $0.url?.path } == ["/prefix/v1/events", "/prefix/v1/events"], "reconnect lost base prefix")
        try require(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == Array(repeating: "Bearer fixture-token", count: 2), "reconnect authentication changed")
        try require(requests.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == [nil, "devices:7"], "reconnect cursor did not retain the last accepted event")
        try require(events.map(\.type) == ["customer.change", "customer.heartbeat"] && events.first?.id == "devices:7", "oversized or rejected event was published")
        try require(fixture.delays == [1], "existing first reconnect policy changed")
    }

}

private final class APIOversizedRealtimeFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".realtime.example.test"
    let invalidMetadata: Bool
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var waits: [TimeInterval] = []
    private var stoppedAt: TimeInterval?
    init(invalidMetadata: Bool) { self.invalidMetadata = invalidMetadata }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return waits }
    var firstStoppedAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return stoppedAt }
    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }; recorded.append(request); return recorded.count
    }
    func recordDelay(_ delay: TimeInterval) { lock.lock(); waits.append(delay); lock.unlock() }
    func stopped() { lock.lock(); stoppedAt = ProcessInfo.processInfo.systemUptime; lock.unlock() }
}

// Reserved fixture hosts are intercepted without DNS or sockets. The streams
// never reach EOF; the first stop proves that the oversized response was retired.
private final class APIOversizedRealtimeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: APIOversizedRealtimeFixture] = [:]
    private var ordinal = 0
    private var activeFixture: APIOversizedRealtimeFixture?
    static func register(_ fixture: APIOversizedRealtimeFixture) { lock.lock(); fixtures[fixture.host] = fixture; lock.unlock() }
    static func remove(_ fixture: APIOversizedRealtimeFixture) { lock.lock(); fixtures.removeValue(forKey: fixture.host); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixtures[request.url?.host ?? ""]; Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        activeFixture = fixture
        ordinal = fixture.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let valid = "event: customer.change\nid: devices:7\ndata: {\"domain\":\"devices\",\"version\":7}\n\n"
        let invalid = fixture.invalidMetadata ? "event: customer.change\nid: devices:8\ndata: {\"domain\":\"devices\",\"version\":1.5}\n\n" : ""
        let wire = ordinal == 1 ? valid + invalid + String(repeating: "x", count: 64 * 1024 + 1)
            : "event: customer.heartbeat\ndata: {}\n\n"
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
    }
    override func stopLoading() { if ordinal == 1 { activeFixture?.stopped() } }
}
