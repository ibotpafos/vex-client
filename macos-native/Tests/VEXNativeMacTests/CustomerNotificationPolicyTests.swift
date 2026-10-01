import XCTest
@testable import VEXNativeMac

final class CustomerNotificationPolicyTests: XCTestCase {
    private func event(_ type: String, _ id: String, _ data: String) -> (CustomerRealtimeEvent, CustomerRealtimeMetadata)? {
        let event = CustomerRealtimeEvent(type: type, id: id, data: data)
        guard let metadata = CustomerRealtimeMetadata.parse(type: type, data: data) else { return nil }
        return (event, metadata)
    }

    func testOnlyRelevantFreshChangeEventsProducePrivacyReducedNotices() throws {
        var policy = CustomerNotificationPolicy()
        let support = try XCTUnwrap(event("customer.change", "support-1", #"{"domain":"support","version":1,"secret":"must-not-leak"}"#))
        let notices = policy.consume(event: support.0, metadata: support.1)

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].title, "Поддержка VEX")
        XCTAssertEqual(notices[0].body, "Есть изменения в поддержке. Откройте клиент для просмотра.")
        XCTAssertFalse(notices[0].body.contains("must-not-leak"))
        XCTAssertFalse(notices[0].title.contains("must-not-leak"))
    }

    func testHeartbeatResyncRevocationInvalidAndDuplicateDoNotProduceNotices() throws {
        var policy = CustomerNotificationPolicy()
        for input in [
            event("customer.heartbeat", "h", "{}"),
            event("customer.session.revoked", "r", #"{"reason":"invalid"}"#),
            event("customer.resync", "sync", #"{"versions":[{"domain":"support"}]}"#),
            event("customer.change", "", #"{"domain":"support","version":1}"#),
            event("customer.change", "unknown", #"{"domain":"account","version":1}"#),
        ] {
            if let input { XCTAssertTrue(policy.consume(event: input.0, metadata: input.1).isEmpty) }
        }
        let release = try XCTUnwrap(event("customer.change", "release-1", #"{"domain":"releases","version":1}"#))
        XCTAssertEqual(policy.consume(event: release.0, metadata: release.1).count, 1)
        XCTAssertTrue(policy.consume(event: release.0, metadata: release.1).isEmpty)
    }

    func testSessionResetForgetsBoundedDedupeState() throws {
        var policy = CustomerNotificationPolicy()
        let input = try XCTUnwrap(event("customer.change", "support-1", #"{"domain":"support","version":1}"#))
        XCTAssertEqual(policy.consume(event: input.0, metadata: input.1).count, 1)
        XCTAssertTrue(policy.consume(event: input.0, metadata: input.1).isEmpty)
        policy.reset()
        XCTAssertEqual(policy.consume(event: input.0, metadata: input.1).count, 1)
    }
}
