import XCTest
@testable import VEXNativeMac

final class ClientDiagnosticsTelemetryTests: XCTestCase {
    func testLegacyReportDecodesWithoutConnectionMeasurements() throws {
        let data = Data(#"{"platform":"macos","app_version":"1","reason":"support","status":"info","vpn_state":"unknown","dns_ok":false,"https_ok":false,"rx_bytes":0,"tx_bytes":0,"samples":{}}"#.utf8)
        let report = try JSONDecoder().decode(ClientDiagnosticsReport.self, from: data)
        XCTAssertNil(report.connectDurationMs)
        XCTAssertNil(report.sessionUptimeSeconds)
        let encoded = try report.dictionary()
        XCTAssertNil(encoded["connect_duration_ms"])
        XCTAssertNil(encoded["session_uptime_seconds"])
    }

    func testMeasuredConnectionFieldsUseExistingServerContract() throws {
        let report = ClientDiagnosticsReport(reason: "dynamic_route", status: "ok",
            vpnState: "connected", dnsOk: false, httpsOk: false, rxBytes: 12, txBytes: 23,
            samples: [:], connectionEvent: "connect_succeeded", connectDurationMs: 1_250,
            transportTo: "awg3_direct", sessionUptimeSeconds: 9)
        let encoded = try report.dictionary()
        XCTAssertEqual(encoded["connect_duration_ms"] as? Int, 1_250)
        XCTAssertEqual(encoded["session_uptime_seconds"] as? Int, 9)
        XCTAssertEqual(encoded["connection_event"] as? String, "connect_succeeded")
        XCTAssertEqual(try JSONDecoder().decode(ClientDiagnosticsReport.self,
            from: JSONEncoder().encode(report)), report)
    }
}
