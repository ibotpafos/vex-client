import XCTest
@testable import VEXNativeMac

final class CustomerRealtimeTests: XCTestCase {
    func testParserPreservesCompleteFramesAndPartialRemainder() throws {
        var parser = CustomerSSEParser()
        let events = parser.append("event: customer.change\nid: devices:7\ndata: {\"domain\":\"devices\",\"version\":7}\n\npart")
        XCTAssertEqual(events, [CustomerRealtimeEvent(type: "customer.change", id: "devices:7", data: "{\"domain\":\"devices\",\"version\":7}")])
        XCTAssertEqual(parser.remainder, "part")
    }

    func testMetadataRejectsUnknownDomainsAndParsesResync() throws {
        XCTAssertNil(CustomerRealtimeMetadata.parse(type: "customer.change", data: #"{"domain":"email","version":1}"#))
        XCTAssertEqual(
            CustomerRealtimeMetadata.parse(type: "customer.resync", data: #"{"versions":[{"domain":"billing","version":2}],"reason":"initial"}"#),
            CustomerRealtimeMetadata(domains: ["billing"], reason: "initial")
        )
    }

    func testReconnectDelayIsBounded() {
        XCTAssertEqual(CustomerRealtimeService.reconnectDelay(attempt: 0), 1)
        XCTAssertEqual(CustomerRealtimeService.reconnectDelay(attempt: 20), 30)
    }
}
