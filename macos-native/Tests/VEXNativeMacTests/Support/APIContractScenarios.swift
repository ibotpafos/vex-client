import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !VEX_API_STANDALONE
@testable import VEXNativeMac
#endif

/// One set of production API scenarios for XCTest and an explicit CLT probe.
enum APIContractScenarios {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    static func appUpdateMetadata() async throws {
        let constructed = AppUpdateCheckResult(updateAvailable: false, required: false,
            latestVersion: "", latestBuild: 0, minSupportedBuild: 0, downloadUrl: "")
        try require(!constructed.isNewerThanInstalledApp(), "existing memberwise initializer changed")
        // Marshaled from Go domain.AppUpdateCheckResponse; release fields use omitempty.
        let cases: [(String, Bool)] = [
            (#"{"updateAvailable":false,"delivery":"native_macos","required":false,"checkedAt":"2026-10-21T00:00:00Z"}"#, false),
            (#"{"updateAvailable":false,"required":false,"currentBuildBlocked":null}"#, false),
            (#"{"updateAvailable":false,"delivery":"native_macos","required":true,"currentBuildBlocked":true,"minConfigSchemaVersion":3,"reason":"no_artifact","checkedAt":"2026-10-21T00:00:00Z"}"#, false),
            (#"{"updateAvailable":true,"delivery":"native_macos","required":true,"currentBuildBlocked":true,"latestVersion":"999.3.0","latestBuild":999,"minSupportedBuild":1,"minConfigSchemaVersion":3,"downloadUrl":"/downloads/update.zip","changelog":"Contract fixture","checksumSha256":"fixture-hash","signatureUrl":"/downloads/update.zip.sig","channel":"stable","reason":"new_build","rolloutPercent":100,"checkedAt":"2026-10-21T00:00:00Z"}"#, true),
        ]
        for (payload, available) in cases {
            var api = VEXAPIClient()
            api.baseURL = URL(string: "https://metadata.example.invalid")
            api.transport.load = { request in
                try verifyAppMetadataRequest(request)
                let body = request.url!.path == "/v1/app/update/check" ? payload : #"{"platform":"macos","channel":"stable"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let update = try await api.appUpdateCheck()
            try require(update.updateAvailable == available, "update availability changed")
            if available {
                try require(update.latestVersion == "999.3.0" && update.latestBuild == 999 && update.minSupportedBuild == 1, "release metadata lost")
                try require(update.downloadUrl == "https://metadata.example.invalid/downloads/update.zip", "download projection changed")
                try require(update.checksumSha256 == "fixture-hash" && update.signatureUrl == "/downloads/update.zip.sig", "integrity metadata lost")
            } else {
                try require(update.latestVersion == "" && update.latestBuild == 0 && update.minSupportedBuild == 0 && update.downloadUrl == "", "omitted Go release fields lost zero-value semantics")
                try require(!update.isNewerThanInstalledApp(), "empty release was offered as an update")
            }
            let original = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            try require(update.required == (original["required"] as? Bool), "required flag lost")
            try require(update.currentBuildBlocked == (original["currentBuildBlocked"] as? Bool), "blocked flag lost")
            try require(update.minConfigSchemaVersion == (original["minConfigSchemaVersion"] as? Int), "schema guard lost")
            let encoded = try JSONEncoder().encode(update)
            if available {
                var expected = original
                expected.removeValue(forKey: "delivery") // platform routing is not a stored Swift field
                expected["downloadUrl"] = "https://metadata.example.invalid/downloads/update.zip"
                let actual = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                try require(NSDictionary(dictionary: actual).isEqual(to: expected), "complete release metadata projection changed")
            }
            let roundTrip = try JSONDecoder().decode(AppUpdateCheckResult.self, from: encoded)
            try require(roundTrip == update, "Codable round trip changed app metadata")
            let remote = try await api.appRemoteConfig()
            try require(remote.platform == "macos" && remote.channel == "stable", "remote-config metadata changed")
        }
        var invalid = ["{}", #"{"required":false}"#, #"{"updateAvailable":false}"#,
            #"{"updateAvailable":false,"required":false,"latestBuild":"bad"}"#].map { Data($0.utf8) }
        let wrong: [Any] = [NSNull(), 0, 1, "false", "true", [Any](), [String: Any]()]
        for field in ["updateAvailable", "required"] {
            for value in wrong {
                var payload: [String: Any] = ["updateAvailable": false, "required": false]
                payload[field] = value
                invalid.append(try JSONSerialization.data(withJSONObject: payload))
            }
        }
        for value in wrong where !(value is NSNull) {
            invalid.append(try JSONSerialization.data(withJSONObject:
                ["updateAvailable": false, "required": false, "currentBuildBlocked": value]))
        }
        for value: Any in [NSNull(), [Any](), [false], true, "false", 0] {
            invalid.append(try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
        }
        for payload in invalid {
            var api = VEXAPIClient()
            api.baseURL = URL(string: "https://metadata.example.invalid")
            api.transport.load = { request in
                (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            do {
                _ = try await api.appUpdateCheck()
                throw Failure("malformed update metadata admitted")
            } catch is DecodingError { }
        }
    }

    private static func verifyAppMetadataRequest(_ request: URLRequest) throws {
        try require(request.httpMethod == "POST", "app metadata method changed")
        try require(["/v1/app/update/check", "/v1/app/remote-config"].contains(request.url!.path), "unexpected metadata route")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let keys: Set<String> = ["platform", "appVersion", "buildNumber", "channel", "coreVersion", "osVersion", "arch", "apiClientVersion", "configSchemaVersion"]
        try require(Set(body.keys) == keys, "app metadata request keys changed")
        try require(body["platform"] as? String == "macos" && body["appVersion"] as? String == VEXAppInfo.version && body["buildNumber"] as? Int == VEXAppInfo.buildNumber, "app identity metadata changed")
        try require(body["channel"] as? String == VEXAppInfo.channel && body["coreVersion"] as? String == VEXAppInfo.coreVersion, "release channel/core metadata changed")
        try require(body["apiClientVersion"] as? String == VEXAppInfo.apiClientVersion && body["configSchemaVersion"] as? Int == VEXAppInfo.configSchemaVersion, "compatibility metadata changed")
        try require(body["osVersion"] as? String == ProcessInfo.processInfo.operatingSystemVersionString, "OS metadata changed")
        #if arch(arm64)
        try require(body["arch"] as? String == "arm64", "architecture changed")
        #else
        try require(body["arch"] as? String == "x64", "architecture changed")
        #endif
    }

    static func locationCapabilities() async throws {
        let cases: [(String, String, String, Int?, Bool)] = [
            ("zero", "available", "healthy", 0, false),
            ("ready", "available", "healthy", 2, true),
            ("legacy", "available", "healthy", nil, true),
            ("negative", "available", "healthy", -1, false),
            ("maintenance", "maintenance", "healthy", 1, false),
            ("hidden", "hidden", "healthy", 1, false),
            ("offline", "available", "offline", 1, false),
            ("unknown", "available", "unknown", 1, false),
            ("degraded", " AVAILABLE ", " Degraded ", 1, true),
        ]
        let payload: [[String: Any]] = cases.map { id, availability, status, count, _ in
            var value: [String: Any] = ["id": id, "country_code": "ZZ", "city": id,
                "availability": availability, "status": status, "healthy_nodes": 2]
            if let count { value["awg3_nodes"] = count }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode([VpnLocation].self, from: data)
        for (location, fixture) in zip(decoded, cases) {
            try require(VEXCountryGroup.isAvailable(location) == fixture.4, "country eligibility mismatch: " + location.id)
            try require(ServerSidebarCatalog.isAvailable(location) == fixture.4, "sidebar eligibility mismatch: " + location.id)
        }
        var api = VEXAPIClient()
        api.transport.load = { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let selected = try await api.vpnLocations(accessToken: "inert-fixture-token")
        try require(selected.map(\.id) == cases.filter { $0.4 }.map { $0.0 }, "API eligibility differs from cards/sidebar")
    }

    static func redirects(method: String) async throws {
        for status in [301, 302, 303, 307, 308] {
            let fixture = try LoopbackRedirectFixture(status: status)
            defer { fixture.close() }
            var request = URLRequest(url: fixture.url)
            request.httpMethod = method
            request.setValue("Bearer inert-fixture-token", forHTTPHeaderField: "Authorization")
            if method == "POST" { request.httpBody = Data("inert-fixture-body".utf8) }
            let (_, response) = try await VEXAPITransport().data(for: request, timeout: 3)
            try require((response as? HTTPURLResponse)?.statusCode == status, "API followed HTTP \(status) redirect for \(method)")
            let requests = try fixture.requests()
            try require(requests == [method + " /start"], "A redirect replayed API work")
            try fixture.closeAndVerify()
        }
    }

    @MainActor
    static func realtimeRedirects() async throws {
        var failures: [String] = []
        for foreign in [false, true] {
            for status in [301, 302, 303, 307, 308] {
                let fixture = try LoopbackRedirectFixture(status: status, foreignAuthority: foreign)
                defer { fixture.close() }
                var statuses: [Bool] = [], events = 0, rejected = 0
                let service = CustomerRealtimeService(
                    baseURL: fixture.url.deletingLastPathComponent(),
                    onStatus: { statuses.append($0) },
                    onSessionRejected: { rejected += 1 }
                ) { _, _ in events += 1 }
                service.start(accessToken: "inert-fixture-token")
                defer { service.stop() }
                try await waitUntil { statuses.count > 1 }
                service.stop()
                let requests = try fixture.requests()
                if requests != ["GET /v1/events"] || statuses.contains(true) || events != 0 || rejected != 0 {
                    failures.append("HTTP \(status) foreign=\(foreign) requests=\(requests) statuses=\(statuses)")
                }
                try fixture.closeAndVerify()
            }
        }
        try require(failures.isEmpty, "SSE followed redirects: " + failures.joined(separator: "; "))
    }

    @MainActor
    static func realtimeStop(fromEvent: Bool) async throws {
        let fixture = try LoopbackRedirectFixture(status: 200, mode: "stream")
        defer { fixture.close() }
        var statuses: [Bool] = [], events = 0, rejected = 0
        var service: CustomerRealtimeService!
        service = CustomerRealtimeService(
            baseURL: fixture.url.deletingLastPathComponent(),
            onStatus: { connected in
                statuses.append(connected)
                if connected && !fromEvent { service.stop() }
            },
            onSessionRejected: { rejected += 1 }
        ) { _, _ in
            events += 1
            service.stop()
        }
        defer { service.stop(); service = nil }
        service.start(accessToken: "inert-fixture-token")
        try await waitUntil { fixture.streamClosed }
        // Let the cancelled URLSession iterator finish its catch/EOF path.
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(statuses == [false, true, false], "Cancelled SSE published a late status: \(statuses)")
        try require(events == (fromEvent ? 1 : 0) && rejected == 0, "Cancellation dispatched a late event/session rejection")
        let requests = try fixture.requests()
        try require(requests == ["GET /v1/events"], "Cancellation reconnected SSE")
        try fixture.closeAndVerify()
    }

    @MainActor
    static func realtimeUnauthorized() async throws {
        let fixture = try LoopbackRedirectFixture(status: 401)
        defer { fixture.close() }
        var statuses: [Bool] = [], events = 0, rejected = 0
        let service = CustomerRealtimeService(
            baseURL: fixture.url.deletingLastPathComponent(),
            onStatus: { statuses.append($0) }, onSessionRejected: { rejected += 1 }
        ) { _, _ in events += 1 }
        defer { service.stop() }
        service.start(accessToken: "inert-fixture-token")
        try await waitUntil { rejected > 0 }
        try require(statuses == [false, false] && events == 0 && rejected == 1, "HTTP401 realtime session contract changed")
        let requests = try fixture.requests()
        try require(requests == ["GET /v1/events"], "HTTP401 replayed a rejected session")
        try fixture.closeAndVerify()
    }

    @MainActor
    private static func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !ready() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "SSE fixture condition timed out")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func bodyDeadline() async throws {
        let fixture = try LoopbackRedirectFixture(status: 200, mode: "stall")
        defer { fixture.close() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await VEXAPITransport().data(for: URLRequest(url: fixture.url), timeout: 0.1)
            throw Failure("stalled body escaped deadline")
        } catch let error as URLError {
            try require(error.code == .timedOut, "deadline classification changed")
        }
        try require(ProcessInfo.processInfo.systemUptime - started < 2, "stalled body retained API operation")
        let requests = try fixture.requests()
        try require(requests == ["GET /start"], "deadline restarted the request")
        try fixture.closeAndVerify()
    }

    static func bodyCancellation() async throws {
        let fixture = try LoopbackRedirectFixture(status: 200, mode: "stall")
        let request = URLRequest(url: fixture.url)
        let task = Task { try await VEXAPITransport().data(for: request, timeout: 5) }
        defer { task.cancel(); fixture.close() }
        try await fixture.waitForRequest()
        task.cancel()
        do {
            _ = try await task.value
            throw Failure("cancelled API returned a body")
        } catch is CancellationError { }
        let requests = try fixture.requests()
        try require(requests == ["GET /start"], "cancellation retried API work")
        try fixture.closeAndVerify()
    }

    static func errorBodies() async throws {
        let cases: [(String, String?, String)] = [
            (#"{"code":17,"message":" visible "}"#, nil, "visible"),
            (#"{"code":" quota ","message":42,"error":" legacy "}"#, "quota", "legacy"),
            (#"{"code":"quota","message":"  ","error":"legacy"}"#, "quota", "legacy"),
            (#"{"code":"quota","message":null,"error":[]}"#, "quota", "HTTP request failed"),
            (#"{"code":{},"debug":"inert-private-fixture"}"#, nil, "HTTP request failed"),
            ("null", nil, "HTTP request failed"),
            ("[]", nil, "HTTP request failed"),
            ("123", nil, "HTTP request failed"),
            ("true", nil, "HTTP request failed"),
            (#"{"message":"inert-private-fixture""#, nil, "HTTP request failed"),
            ("<html>inert-private-fixture</html>", nil, "HTTP request failed"),
            (#"" legacy string ""#, nil, "legacy string"),
            (" legacy text ", nil, "legacy text"),
        ]
        for (body, code, message) in cases {
            var api = VEXAPIClient()
            api.transport.load = { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            do {
                _ = try await api.billingPlans()
                throw Failure("expected classified HTTP failure")
            } catch let VEXAPIError.http(status, actualMessage, actualCode, _) {
                try require(status == 400, "HTTP status changed")
                try require(actualCode == code, "Error code mismatch: " + body)
                try require(actualMessage == message, "Error message mismatch: " + body)
            }
        }
    }

    static func baseURLConfiguration() async throws {
        try require(VEXAPIConfiguration.resolve(nil)?.absoluteString == "https://vexguard.app", "missing base lost production default")
        try require(VEXAPIConfiguration.resolve("")?.absoluteString == "https://vexguard.app", "empty base lost default")
        for value in [" ", "relative/path", "file:///private/fixture", "https://user:fixture@example.invalid", "https://example.invalid?", "https://example.invalid#", "http://[invalid", "https://example.invalid:65536"] {
            try require(VEXAPIConfiguration.resolve(value) == nil, "invalid base was replaced by an API origin")
        }
        for (value, expected) in [
            ("http://127.0.0.1:45678/gateway///", "http://127.0.0.1:45678/gateway/v1/billing/plans"),
            ("https://staging.example.invalid", "https://staging.example.invalid/v1/billing/plans"),
        ] {
            var api = VEXAPIClient()
            api.baseURL = VEXAPIConfiguration.resolve(value)
            api.transport.load = { request in
                try require(request.url?.absoluteString == expected, "base path or custom origin changed")
                return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let plans = try await api.billingPlans()
            try require(plans.isEmpty, "valid API response changed")
        }
    }

    static func invalidBaseURLs() async throws {
        for value in ["relative/path", "file:///private/fixture", "https://user:fixture@example.invalid", "https://example.invalid?route=other", "https://example.invalid#fragment", "http://[invalid", "https://example.invalid:65536"] {
            var api = VEXAPIClient()
            api.baseURL = URL(string: value)
            api.transport.load = { _ in
                throw Failure("invalid API configuration reached transport")
            }
            do {
                _ = try await api.billingPlans()
                throw Failure("invalid API configuration returned a response")
            } catch let error as VEXAPIError {
                try require(error.code == "invalid_api_base_url", "configuration failure was not classified")
                try require(!VEXAPIError.isServerUnavailable(error), "configuration failure became a server outage")
            }
        }
    }

    static func maintenanceClassification() async throws {
        var api = VEXAPIClient()
        api.transport.load = { request in
            (Data(#"{"code":"maintenance","message":42,"error":"temporary"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        do {
            _ = try await api.me(accessToken: "inert-fixture-token")
            throw Failure("expected maintenance")
        } catch let error as VEXAPIError {
            try require(error.code == "maintenance", "maintenance code lost")
            try require(!error.isUnauthorized, "maintenance became session expiry")
            try require(error.errorDescription == VEXAPIError.technicalWorksMessage, "maintenance presentation changed")
        }
    }
}

/// Real HTTP on a private loopback port. Never uses VPN, DNS, keys or a live API.
private final class LoopbackRedirectFixture {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vex-api-redirect-" + UUID().uuidString)
    private let process = Process()
    private let output = Pipe()
    private let terminated = DispatchSemaphore(value: 0)
    private var closed = false
    private var cleanupTimedOut = false
    var url = URL(string: "http://127.0.0.1")!

    var streamClosed: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("closed").path) }

    init(status: Int, mode: String = "redirect", foreignAuthority: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, directory.appendingPathComponent("requests").path, String(status), mode, foreignAuthority ? "1" : "0"]
        process.standardOutput = output
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        process.standardError = Pipe()
        do {
            try process.run()
            try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
            let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let line, let port = UInt16(line), port > 0 else {
                throw NSError(domain: "LoopbackRedirectFixture", code: 1)
            }
            url = URL(string: "http://127.0.0.1:\(port)/start")!
        } catch {
            close()
            throw error
        }
    }

    func requests() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func waitForRequest() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests").path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw APIContractScenarios.Failure("fixture request did not start") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if process.isRunning {
            process.terminate()
            // waitUntilExit can block a cooperative executor's run loop after
            // the child has exited. The handler is installed before launch.
            cleanupTimedOut = terminated.wait(timeout: .now() + 2) == .timedOut
        }
        try? output.fileHandleForReading.close()
        if !cleanupTimedOut { try? FileManager.default.removeItem(at: directory) }
    }

    func closeAndVerify() throws {
        close()
        try APIContractScenarios.require(!cleanupTimedOut, "owned HTTP fixture did not terminate within its cleanup deadline")
    }

    private static let script = #"""
import http.server, pathlib, sys, time, threading
trace, status, mode = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
foreign = sys.argv[4] == '1'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def handle_api(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with trace.open('a') as output: output.write(self.command + ' ' + self.path + '\n')
        initial = self.path in ('/start', '/v1/events')
        self.send_response(status if initial else 200)
        if mode == 'redirect' and initial:
            self.send_header('Location', f'http://127.0.0.1:{target.server_port}/target' if foreign else '/target')
        if mode == 'stream':
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(b'event: customer.heartbeat\ndata: {}\n\n')
            self.wfile.flush()
            self.connection.settimeout(3)
            if self.connection.recv(1) == b'': trace.with_name('closed').write_text('closed')
            return
        self.send_header('Content-Length', '2')
        self.end_headers()
        if mode == 'stall': time.sleep(10)
        else: self.wfile.write(b'{}')
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) if foreign else server
if foreign: threading.Thread(target=target.serve_forever, daemon=True).start()
server.timeout = 0.1
print(server.server_port, flush=True)
deadline = time.monotonic() + 15
while time.monotonic() < deadline: server.handle_request()
server.server_close()
"""#
}
