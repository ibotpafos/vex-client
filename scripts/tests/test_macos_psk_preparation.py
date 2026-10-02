#!/usr/bin/env python3
"""No live HTTP/helper/stores: real SDK URLProtocol and pure preparation boundary."""
import hashlib, os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"
FIXTURE = r'''
import Foundation
final class MockURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var data = Data()
    static var status = 201
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating:0,count:1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength:buffer.count)
                if n <= 0 { break }; bytes.append(buffer,count:n)
            }
            captured.httpBody = bytes
        }
        Self.requests.append(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main @MainActor struct Main {
    static func need(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    static func main() async throws {
        let device = "vex_11111111111111111111111111111111"
        let rotation = "pskr_22222222222222222222222222222222"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let now = Date()
        let deadline = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))
        let receipt = PSKRotationPreparationReceipt(rotationID: rotation, profileVersion: 8,
            profileDigest: digest, deadlineAt: deadline)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = VEXAPIClient(urlSession: session, baseURL: URL(string: "https://offline.invalid/base")!)
        MockURLProtocol.data = try JSONEncoder().encode(receipt)
        let received = try await api.preparePSKRotation(accessToken: "fixture-token", deviceID: device,
            expectedProfileVersion: 7, expectedLocationID: "de", routingMode: .allExceptRu,
            bypassRegion: "ru", routingPolicyVersion: "42", idempotencyKey: "fixture-stable-key")
        need(received == receipt, "receipt decode")
        let post = MockURLProtocol.requests.removeFirst()
        need(post.httpMethod == "POST" && post.url?.path == "/base/v1/vpn/psk-rotations/prepare-routing", "SDK exact route")
        need(post.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
             && post.value(forHTTPHeaderField: "Idempotency-Key") == "fixture-stable-key", "SDK auth and replay key")
        let body = try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: Any]
        need(Set(body.keys) == Set(["device_id", "expected_profile_version", "expected_location_id", "client_platform",
            "routing_mode", "bypass_region", "routing_policy_version"]), "exact nonsecret request fields")
        need(body["device_id"] as? String == device && body["client_platform"] as? String == "macos"
             && body["routing_mode"] as? String == "all_except_ru" && body["bypass_region"] as? String == "ru"
             && body["expected_profile_version"] as? Int == 7 && body["expected_location_id"] as? String == "de", "SDK bound tuple")
        for version in [0, -1, Int.max] {
            do { _ = try await api.preparePSKRotation(accessToken: "t", deviceID: device, expectedProfileVersion: version,
                 expectedLocationID: "de", routingMode: .fullTunnel, bypassRegion: nil, routingPolicyVersion: "", idempotencyKey: "key"); need(false, "invalid version sent") }
            catch let error as VEXAPIError { if case .invalidRequest = error {} else { need(false, "wrong error") } }
        }
        for (id, location, mode, region, key) in [
            ("bad/id", "de", VpnRoutingMode.fullTunnel, nil, "key"),
            (device, "", .fullTunnel, nil, "key"), (device, "de\n", .fullTunnel, nil, "key"),
            (device, "de", .fullTunnel, "ru", "key"), (device, "de", .allExceptRu, nil, "key"),
            (device, "de", .allExceptRu, "xx", "key"), (device, "de", .fullTunnel, nil, "\r\n"),
            (device, "de", .fullTunnel, nil, String(repeating:"x", count:129))] as [(String,String,VpnRoutingMode,String?,String)] {
            do { _ = try await api.preparePSKRotation(accessToken:"t", deviceID:id, expectedProfileVersion:7,
                 expectedLocationID:location, routingMode:mode, bypassRegion:region, routingPolicyVersion:"", idempotencyKey:key); need(false,"invalid tuple sent") }
            catch let error as VEXAPIError { if case .invalidRequest = error {} else { need(false,"wrong error") } }
        }
        need(MockURLProtocol.requests.isEmpty, "invalid requests never reached transport")
        MockURLProtocol.status = 401; MockURLProtocol.data = Data("{}".utf8)
        do { _ = try await api.preparePSKRotation(accessToken:"expired", deviceID:device, expectedProfileVersion:7,
             expectedLocationID:"de", routingMode:.fullTunnel, bypassRegion:nil, routingPolicyVersion:"", idempotencyKey:"key"); need(false,"401 accepted") }
        catch let error as VEXAPIError { need(error.isUnauthorized,"typed auth rejection") }

        let context = NativePSKPreparation.Context(accountID:"owner", installationID:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            deviceID:device, profileVersion:7, locationID:"de", routingMode:.allExceptRu, bypassRegion:"ru", routingPolicyVersion:"42")
        need(context.idempotencyKey == context.idempotencyKey && context.idempotencyKey.count < 128, "stable bounded replay identity")
        let changed = NativePSKPreparation.Context(accountID:"other-owner", installationID:context.installationID,
            deviceID:device, profileVersion:7, locationID:"de", routingMode:.allExceptRu, bypassRegion:"ru", routingPolicyVersion:"42")
        need(context.idempotencyKey != changed.idempotencyKey, "owner-bound replay")
        var current = true, calls = 0, queued: [NativePushPSKEvent] = [], processed = 0
        func dependencies(_ result: PSKRotationPreparationReceipt, revoke: Bool = false, enqueueFailure: Bool = false) -> NativePSKPreparation.Dependencies {
            .init(scopeIsCurrent:{current}, prepare:{ c, key in
                need(c == context && key == context.idempotencyKey,"coordinator carries context/replay"); calls += 1
                if revoke { current = false }; return result
            }, enqueue:{ event in
                if enqueueFailure { throw CocoaError(.fileWriteOutOfSpace) }; queued.append(event)
            }, processStagedEvents:{ processed += 1 })
        }
        try await NativePSKPreparation.prepare(context:context, dependencies:dependencies(receipt), now:{now})
        need(calls==1 && queued.count==1 && processed==1,"prepare then event then existing consumer")
        need(queued[0].eventID == "psk-rotation:\(rotation):profile_updated" && queued[0].deviceID == device
             && queued[0].profileVersion == 8 && queued[0].kind == .profile_updated,"genuine derived event")
        calls=0; queued=[]; processed=0; current=false
        do { try await NativePSKPreparation.prepare(context:context, dependencies:dependencies(receipt), now:{now}); need(false,"stale before sent") } catch {}
        need(calls==0 && queued.isEmpty && processed==0,"stale before no effects")
        current=true
        do { try await NativePSKPreparation.prepare(context:context, dependencies:dependencies(receipt,revoke:true), now:{now}); need(false,"stale completion admitted") } catch {}
        need(calls==1 && queued.isEmpty && processed==0,"stale completion no queue/consumer")
        current=true; calls=0
        var invalids:[PSKRotationPreparationReceipt] = []
        var bad=receipt; bad.rotationID="bad/id"; invalids.append(bad)
        bad=receipt; bad.profileVersion=7; invalids.append(bad)
        bad=receipt; bad.profileVersion=9; invalids.append(bad)
        bad=receipt; bad.profileDigest="sha256:"+String(repeating:"g",count:64); invalids.append(bad)
        bad=receipt; bad.deadlineAt=ISO8601DateFormatter().string(from:now.addingTimeInterval(-1)); invalids.append(bad)
        bad=receipt; bad.deadlineAt=ISO8601DateFormatter().string(from:now.addingTimeInterval(3600)); invalids.append(bad)
        for bad in invalids {
            do { try await NativePSKPreparation.prepare(context:context, dependencies:dependencies(bad), now:{now}); need(false,"invalid receipt admitted") } catch {}
        }
        need(queued.isEmpty && processed==0,"invalid receipt no persistence/ACK/helper")
        do { try await NativePSKPreparation.prepare(context:context, dependencies:dependencies(receipt,enqueueFailure:true), now:{now}); need(false,"enqueue failure consumed") } catch {}
        need(queued.isEmpty && processed==0,"failed durable enqueue no consume")
        print("PSK explicit preparation PASS SDK auth/body/replay/401/invalid-request; stable owner identity; pre/post-await scope; genuine derived event; invalid receipt and enqueue failure no ACK/helper")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="vex-psk-prepare-") as directory:
    d = Path(directory); (d/"main.swift").write_text(FIXTURE)
    files = [S/"Models/VEXModels.swift"] + [S/"Services"/n for n in [
        "VEXAPIClient.swift", "NativePSKIdentifier.swift", "NativePushSecureFileStore.swift",
        "NativePushPSKEventQueue.swift", "NativePSKPreparation.swift"]]
    for f in files: print("source_sha256=" + hashlib.sha256(f.read_bytes()).hexdigest() + " " + str(f))
    cmd = ["swiftc","-swift-version","5","-parse-as-library",*map(str, files),str(d/"main.swift"),"-o",str(d/"probe")]
    p = subprocess.run(cmd, text=True, capture_output=True)
    print(p.stdout, end=""); print(p.stderr,end="",file=sys.stderr)
    if p.returncode: raise SystemExit(p.returncode)
    p = subprocess.run([str(d/"probe")],text=True,capture_output=True)
    print(p.stdout,end="");print(p.stderr,end="",file=sys.stderr)
    raise SystemExit(p.returncode)
