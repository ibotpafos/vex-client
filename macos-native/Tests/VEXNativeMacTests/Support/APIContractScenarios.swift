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

    init(status: Int, mode: String = "redirect") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, directory.appendingPathComponent("requests").path, String(status), mode]
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
import http.server, pathlib, sys, time
trace, status, mode = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def handle_api(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with trace.open('a') as output: output.write(self.command + ' ' + self.path + '\n')
        self.send_response(status if self.path == '/start' else 200)
        if mode == 'redirect' and self.path == '/start': self.send_header('Location', '/target')
        self.send_header('Content-Length', '2')
        self.end_headers()
        if mode == 'stall': time.sleep(10)
        else: self.wfile.write(b'{}')
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 0.1
print(server.server_port, flush=True)
deadline = time.monotonic() + 15
while time.monotonic() < deadline: server.handle_request()
server.server_close()
"""#
}
