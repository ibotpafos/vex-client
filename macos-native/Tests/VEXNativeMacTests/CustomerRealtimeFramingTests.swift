import Foundation
import XCTest
@testable import VEXNativeMac

final class CustomerRealtimeFramingTests: XCTestCase {
    private let limit = 64 * 1024
    private let frame = "event: customer.change\nid: devices:7\ndata: {\"domain\":\"devices\",\"version\":7}\n\n"
    private let expected = CustomerRealtimeEvent(
        type: "customer.change", id: "devices:7", data: "{\"domain\":\"devices\",\"version\":7}"
    )

    func testCRLFRemainsOneNewlineAcrossEveryChunkBoundary() {
        for newline in ["\n", "\r", "\r\n"] {
            let wire = frame.replacingOccurrences(of: "\n", with: newline)
            for split in 0...wire.utf8.count {
                let bytes = Array(wire.utf8)
                var parser = CustomerSSEParser()
                let first = String(decoding: bytes[..<split], as: UTF8.self)
                let second = String(decoding: bytes[split...], as: UTF8.self)
                let events = parser.append(first) + parser.append(second)
                XCTAssertEqual(events, [expected], "Newline \(newline.debugDescription), split \(split)")
                XCTAssertTrue(parser.remainder.isEmpty)
            }
        }
    }

    func testOversizedCompleteFrameIsRejected() {
        var parser = CustomerSSEParser()
        let wire = "event: customer.change\ndata: " + String(repeating: "x", count: limit) + "\n\n"
        XCTAssertEqual(parser.append(wire).count, 0)
        XCTAssertTrue(parser.remainder.isEmpty)
        XCTAssertEqual(parser.append(frame).count, 0, "A rejected stream must be replaced, not resumed from a suffix")
    }

    func testOversizedUnfinishedFrameReleasesItsRemainder() {
        var parser = CustomerSSEParser()
        XCTAssertEqual(parser.append(String(repeating: "x", count: limit + 1)).count, 0)
        XCTAssertTrue(parser.remainder.isEmpty)
        XCTAssertEqual(parser.append("\n\n" + frame).count, 0)
    }

    func testBudgetUsesUTF8BytesIncludingCombiningMarks() {
        var parser = CustomerSSEParser()
        // One extended grapheme can contain many scalars; String.count is no byte bound.
        let wire = "data: e" + String(repeating: "\u{0301}", count: limit)
        XCTAssertEqual(parser.append(wire).count, 0)
        XCTAssertTrue(parser.remainder.isEmpty)
    }

    func testExactBudgetAndManySmallFramesAreAccepted() {
        let prefix = "event: customer.change\ndata: "
        var parser = CustomerSSEParser()
        let padding = String(repeating: "x", count: limit - prefix.utf8.count - 2)
        XCTAssertEqual(parser.append(prefix + padding + "\n\n").map(\.data), [padding])
        XCTAssertTrue(parser.remainder.isEmpty)
        let count = 3_000
        XCTAssertEqual(parser.append(String(repeating: frame, count: count)), Array(repeating: expected, count: count))
        XCTAssertTrue(parser.remainder.isEmpty)
    }

    func testByteDecoderPreservesUnicodeAndMixedNewlines() {
        var decoder = CustomerSSEWireDecoder()
        let data = "Привет 👨‍👩‍👧‍👦 e\u{0301}"
        let wire = "event: customer.heartbeat\r\ndata: \(data)\r\n\r\n" + frame
        let events = wire.utf8.flatMap { decoder.append($0) }
        XCTAssertEqual(events, [CustomerRealtimeEvent(type: "customer.heartbeat", id: "", data: data), expected])
    }

    func testByteDecoderRejectsEndlessLineBeforeAcceptingAnySuffix() {
        var decoder = CustomerSSEWireDecoder()
        for _ in 0...limit { XCTAssertTrue(decoder.append(0x78).isEmpty) }
        XCTAssertEqual(("\n\n" + frame).utf8.flatMap { decoder.append($0) }.count, 0)
    }

    func testIncompleteEOFDoesNotPublishAnEvent() {
        var decoder = CustomerSSEWireDecoder()
        XCTAssertTrue(frame.dropLast().utf8.flatMap { decoder.append($0) }.isEmpty)
        var parser = CustomerSSEParser()
        XCTAssertTrue(parser.append(String(frame.dropLast())).isEmpty)
        XCTAssertTrue(parser.append("").isEmpty)
    }

    @MainActor
    func testOversizedResponseIsCancelledAndReconnectKeepsLastEventID() async throws {
        let fixture = RealtimeFramingFixture()
        RealtimeFramingProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RealtimeFramingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RealtimeFramingProtocol.fixture = nil }
        let firstStopped = expectation(description: "Oversized response closed before EOF")
        let reconnected = expectation(description: "Existing reconnect path receives next event")
        fixture.onFirstStop = { firstStopped.fulfill() }
        var events: [CustomerRealtimeEvent] = []
        let service = CustomerRealtimeService(
            baseURL: URL(string: "https://realtime.example.test/prefix")!, session: session
        ) { event, _ in
            events.append(event)
            if event.type == "customer.heartbeat" { reconnected.fulfill() }
        }
        defer { service.stop() }
        service.start(accessToken: "fixture-token")
        await fulfillment(of: [firstStopped, reconnected], timeout: 4)
        service.stop()
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/prefix/v1/events", "/prefix/v1/events"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, Array(repeating: "Bearer fixture-token", count: 2))
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Last-Event-ID") }, [nil, "devices:7"])
        XCTAssertEqual(events.map(\.type), ["customer.change", "customer.heartbeat"])
        XCTAssertEqual(events.first?.id, "devices:7")
    }
}

// URLProtocol consumes a reserved fixture hostname without creating a socket.
// Neither response reaches EOF: only cancellation can stop the first stream.
private final class RealtimeFramingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var onFirstStop: (() -> Void)?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return recorded.count
    }
}

private final class RealtimeFramingProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: RealtimeFramingFixture?
    private var ordinal = 0
    private var activeFixture: RealtimeFramingFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else { return }
        activeFixture = fixture
        ordinal = fixture.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let wire = ordinal == 1
            ? "event: customer.change\nid: devices:7\ndata: {\"domain\":\"devices\",\"version\":7}\n\n" + String(repeating: "x", count: 64 * 1024 + 1)
            : "event: customer.heartbeat\ndata: {}\n\n"
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
    }
    override func stopLoading() {
        if ordinal == 1 { activeFixture?.onFirstStop?() }
    }
}
