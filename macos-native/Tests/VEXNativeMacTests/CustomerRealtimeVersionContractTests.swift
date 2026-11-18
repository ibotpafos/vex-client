import Foundation
import XCTest
@testable import VEXNativeMac

final class CustomerRealtimeVersionContractTests: XCTestCase {
    func testBooleansCannotMasqueradeAsNumericVersions() {
        for version in ["true", "false"] {
            XCTAssertNil(CustomerRealtimeMetadata.parse(type: "customer.change", data: "{\"domain\":\"devices\",\"version\":\(version)}"), version)
        }
    }

    func testFractionalAndOutOfRangeVersionsRejectAfterFraming() {
        for version in ["0", "-1", "0.5", "1.5", "9223372036854775808", "18446744073709551615", "1e30", "null", "\"7\""] {
            let data = "{\"domain\":\"devices\",\"version\":\(version)}"
            var decoder = CustomerSSEWireDecoder()
            let events = "event: customer.change\r\ndata: \(data)\r\n\r\n".utf8.flatMap { decoder.append($0) }
            XCTAssertEqual(events.count, 1)
            XCTAssertNil(events.first.flatMap { CustomerRealtimeMetadata.parse(type: $0.type, data: $0.data) }, version)
        }
    }

    func testFullPositiveInt64RangeRemainsValidAfterFraming() {
        for version in ["1", "9007199254740991", "9007199254740992", "9007199254740993", "9223372036854775806", "9223372036854775807"] {
            var decoder = CustomerSSEWireDecoder()
            let data = "{\"domain\":\"devices\",\"version\":\(version)}"
            let events = "event: customer.change\r\nid: devices:\(version)\r\ndata: \(data)\r\n\r\n".utf8.flatMap { decoder.append($0) }
            XCTAssertEqual(events.first?.id, "devices:\(version)")
            XCTAssertEqual(events.first.flatMap { CustomerRealtimeMetadata.parse(type: $0.type, data: $0.data) },
                           CustomerRealtimeMetadata(domains: ["devices"], reason: ""), version)
        }
    }
}
