#!/usr/bin/env python3
"""Compile VEX's real PSK rotation API client against a URLProtocol-only transport."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
MODELS = ROOT / "macos-native/Sources/VEXNativeMac/Models/VEXModels.swift"
API = ROOT / "macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift"

fixture = r'''
import Foundation

final class MockURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var responses: [(Int, Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 { data.append(buffer, count: count) } else { break }
            }
            stream.close()
            captured.httpBody = data
        }
        MockURLProtocol.requests.append(captured)
        let (status, data) = MockURLProtocol.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func response(_ body: String, _ status: Int = 200) { MockURLProtocol.responses.append((status, Data(body.utf8))) }
func json(_ object: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)! }
func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

@main struct Main {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = VEXAPIClient(urlSession: URLSession(configuration: config), baseURL: URL(string: "https://api.example.test/base")!)
        let device = "11111111-2222-4333-8444-555555555555"
        let rotation = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        response(json(["rotation_id": rotation, "activate": false, "current_version": 3, "profile_version": 4, "profile_digest": digest, "deadline_at": "2026-10-02T12:00:00Z", "profile": ["version": 4, "revoked": false, "rotation_required": true, "device_id": device, "client_public_key": "client", "client_key_epoch": 9, "expires_at": "2026-10-03T12:00:00Z", "authorization": ["algorithm": "ed25519", "key_id": "key", "payload_base64": "payload", "signature_base64": "signature"]]]))
        let current = try await api.currentPSKRotation(accessToken: "token", deviceID: device)
        require(current.profileVersion == 4 && current.activate == false && current.profile.clientKeyEpoch == 9 && current.profile.authorization?.keyID == "key", "current profile lost server fields")
        let get = MockURLProtocol.requests.removeFirst()
        require(get.httpMethod == "GET", "GET method")
        require(get.value(forHTTPHeaderField: "Authorization") == "Bearer token" && get.value(forHTTPHeaderField: "X-Vex-Platform") == "macos", "GET headers")
        require(get.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery } == "device_id=11111111-2222-4333-8444-555555555555&platform=macos", "escaped query")

        response(json(["rotation_id": rotation, "accepted": true, "replayed": false]))
        let ack = try await api.acknowledgePSKRotation(accessToken: "token", rotationID: rotation.uppercased(), deviceID: device, profileVersion: 4, profileDigest: digest)
        require(ack.accepted && !ack.replayed, "ACK decode")
        let post = MockURLProtocol.requests.removeFirst()
        require(post.httpMethod == "POST" && post.url?.path == "/base/v1/vpn/psk-rotations/\(rotation)/ack", "ACK path/method")
        require(post.value(forHTTPHeaderField: "Authorization") == "Bearer token" && post.value(forHTTPHeaderField: "Content-Type") == "application/json", "ACK headers")
        let body = try JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as! [String: Any]
        require((body["device_id"] as? String) == device && (body["profile_version"] as? Int) == 4 && (body["profile_digest"] as? String) == digest, "exact ACK JSON")

        func strictEnvelope(_ currentVersion: String?) -> String {
            var fields = ["\"rotation_id\":\"\(rotation)\"", "\"activate\":false"]
            if let currentVersion { fields.append("\"current_version\":\(currentVersion)") }
            fields += ["\"profile_version\":4", "\"profile_digest\":\"\(digest)\"", "\"deadline_at\":\"2026-10-02T12:00:00Z\"", "\"profile\":{}"]
            return "{" + fields.joined(separator: ",") + "}"
        }
        for invalidInteger in ["true", "3.5", "1e999", "9223372036854775808"] {
            response(strictEnvelope(invalidInteger))
            do { _ = try await api.currentPSKRotation(accessToken: "token", deviceID: device); fatalError("invalid Int decoded: \(invalidInteger)") } catch is DecodingError {}
        }
        response(strictEnvelope(nil))
        do { _ = try await api.currentPSKRotation(accessToken: "token", deviceID: device); fatalError("missing Int decoded") } catch is DecodingError {}
        response("{}", 401)
        do { _ = try await api.currentPSKRotation(accessToken: "token", deviceID: device); fatalError("401 did not propagate") } catch let error as VEXAPIError { require(error.isUnauthorized, "typed 401") }

        let before = MockURLProtocol.requests.count
        for invalidDigest in [String(repeating: "a", count: 64), "SHA256:" + String(repeating: "a", count: 64), "sha256:" + String(repeating: "g", count: 64), "bad"] {
            do { _ = try await api.acknowledgePSKRotation(accessToken: "token", rotationID: rotation, deviceID: device, profileVersion: 4, profileDigest: invalidDigest); fatalError("invalid ACK digest sent") } catch let error as VEXAPIError { if case .invalidRequest = error {} else { fatalError("wrong local error") } }
        }
        do { _ = try await api.acknowledgePSKRotation(accessToken: "token", rotationID: "bad/id", deviceID: device, profileVersion: 0, profileDigest: digest); fatalError("invalid ACK sent") } catch let error as VEXAPIError { if case .invalidRequest = error {} else { fatalError("wrong local error") } }
        require(MockURLProtocol.requests.count == before, "invalid ACK made network request")
        print("psk_rotation_urlprotocol=true strict_int=true typed_401=true local_validation=true")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="vex-psk-api-") as directory:
    directory = Path(directory)
    main = directory / "main.swift"
    binary = directory / "probe"
    main.write_text(fixture)
    compiled = subprocess.run(["swiftc", str(__import__("pathlib").Path(__file__).resolve().parents[2]/"macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift"),  "-swift-version", "5", "-parse-as-library", str(MODELS), str(API), str(main), "-o", str(binary)], text=True, capture_output=True)
    print(compiled.stdout, end="")
    print(compiled.stderr, end="", file=sys.stderr)
    print("models_sha256=" + hashlib.sha256(MODELS.read_bytes()).hexdigest())
    print("api_sha256=" + hashlib.sha256(API.read_bytes()).hexdigest())
    if compiled.returncode:
        raise SystemExit(compiled.returncode)
    ran = subprocess.run([str(binary)], text=True, capture_output=True)
    print(ran.stdout, end="")
    print(ran.stderr, end="", file=sys.stderr)
    raise SystemExit(ran.returncode)
