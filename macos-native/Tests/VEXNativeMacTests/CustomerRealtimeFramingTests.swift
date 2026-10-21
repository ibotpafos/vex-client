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
        try await APIContractScenarios.oversizedRealtimeReconnect(invalidMetadata: false)
    }

    @MainActor
    func testRejectedMetadataDoesNotAdvanceReconnectCursor() async throws {
        try await APIContractScenarios.oversizedRealtimeReconnect(invalidMetadata: true)
    }
}
