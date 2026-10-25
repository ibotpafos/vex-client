import Foundation
import XCTest
@testable import VEXNativeMac

final class CustomerRealtimeResyncContractTests: XCTestCase {
    func testLegacyNullVersionsPreserveResyncReason() {
        for reason in ["broker_error", "initial", "reconnect", "subscriber_overflow", "resync"] {
            let data = "{\"versions\":null,\"reason\":\"\(reason)\"}"
            XCTAssertEqual(CustomerRealtimeMetadata.parse(type: "customer.resync", data: data),
                           CustomerRealtimeMetadata(domains: [], reason: reason))
        }
        XCTAssertEqual(CustomerRealtimeMetadata.parse(type: "customer.resync", data: "{\"versions\":null}"),
                       CustomerRealtimeMetadata(domains: [], reason: "resync"))
    }

    func testMalformedAndMissingVersionsStillReject() {
        for data in ["{}", "{\"versions\":true}", "{\"versions\":1}", "{\"versions\":\"null\"}", "{\"versions\":{}}"] {
            XCTAssertNil(CustomerRealtimeMetadata.parse(type: "customer.resync", data: data))
        }
    }

    func testNonemptyAndEmptyArraysRemainCompatible() {
        XCTAssertEqual(CustomerRealtimeMetadata.parse(type: "customer.resync", data: "{\"versions\":[]}"),
                       CustomerRealtimeMetadata(domains: [], reason: "resync"))
        let data = #"{"versions":[{"domain":"devices"},{"domain":"unknown"},{"domain":"billing"},{"domain":"devices"}],"reason":"initial"}"#
        XCTAssertEqual(CustomerRealtimeMetadata.parse(type: "customer.resync", data: data),
                       CustomerRealtimeMetadata(domains: ["billing", "devices"], reason: "initial"))
    }

    func testByteDecoderCarriesLegacyNullBrokerResync() {
        var decoder = CustomerSSEWireDecoder()
        let data = "{\"versions\":null,\"reason\":\"broker_error\"}"
        let events = "event: customer.resync\r\ndata: \(data)\r\n\r\n".utf8.flatMap { decoder.append($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first.flatMap { CustomerRealtimeMetadata.parse(type: $0.type, data: $0.data) },
                       CustomerRealtimeMetadata(domains: [], reason: "broker_error"))
    }
}
