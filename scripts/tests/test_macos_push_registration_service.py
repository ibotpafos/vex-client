#!/usr/bin/env python3
"""Compiles the production Swift service body with a fake-only async registrar."""
from pathlib import Path
import hashlib, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'macos-native/Sources/VEXNativeMac/Services/NativePushRegistrationService.swift'
if len(sys.argv) == 2:
    candidate = Path(sys.argv[1])
    SOURCE = candidate / SOURCE.relative_to(ROOT) if candidate.is_dir() else candidate
source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
main = r'''import Combine
import Foundation

@MainActor final class FakeRegistrar: NativePushRegistrationRegistrar {
    var requests: [NativePushRegistrationRequest] = []
    var failNext = false
    var pause = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func registerNativePush(_ request: NativePushRegistrationRequest) async throws {
        requests.append(request)
        entryContinuation?.resume()
        entryContinuation = nil
        if pause { await withCheckedContinuation { continuation = $0 } }
        if failNext { failNext = false; throw FixtureError.failed }
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilCallCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }
}
enum FixtureError: Error { case failed }

@main struct Main {
    @MainActor static func settle(_ turns: Int = 4) async {
        for _ in 0..<turns { await Task.yield() }
    }
    @MainActor static func waitUntilStatus(_ service: NativePushRegistrationService, _ expected: NativePushRegistrationStatus) async -> Bool {
        // Bounded observation, not a fixed scheduling assumption: completion is
        // accepted only when the production service publishes its final state.
        for _ in 0..<10_000 {
            if service.status == expected { return true }
            await Task.yield()
        }
        return false
    }
    @MainActor static func main() async {
        let fake = FakeRegistrar()
        let service = NativePushRegistrationService(registrar: fake, maximumTokenBytes: 8)
        service.registerAppleDeviceToken(Data([0, 1, 255]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await settle()
        let defaultDisabled = fake.requests.isEmpty && service.status == .disabled

        service.setRegistrationEnabled(true)
        service.registerAppleDeviceToken(Data([0, 1, 255]), accountID: " A ", deviceID: " device-1 ", accessToken: " token-A ", sessionGeneration: 1)
        await fake.waitUntilCallCount(1)
        let firstCompleted = await waitUntilStatus(service, .registered)
        let first = firstCompleted && fake.requests.count == 1 && fake.requests[0].provider == "apns" && fake.requests[0].token == "0001ff" && service.status == .registered

        service.registerAppleDeviceToken(Data([0, 1, 255]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await settle()
        let deduplicated = fake.requests.count == 1

        // Queue a refreshed token, then receive the already-successful token again
        // before queued work starts. The newest callback must supersede token 09.
        service.registerAppleDeviceToken(Data([9]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        service.registerAppleDeviceToken(Data([0, 1, 255]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await settle()
        let dedupeSupersedesQueued = fake.requests.count == 1 && service.status == .registered

        fake.pause = true
        service.registerAppleDeviceToken(Data([8]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await fake.waitUntilCallCount(2)
        service.registerAppleDeviceToken(Data([8]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        let sameTupleInflight = fake.requests.count == 2
        fake.pause = false
        fake.release()
        _ = await waitUntilStatus(service, .registered)

        service.registerAppleDeviceToken(Data([2]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await fake.waitUntilCallCount(3)
        let refreshedTokenCompleted = await waitUntilStatus(service, .registered)
        let refreshedToken = refreshedTokenCompleted && fake.requests.count == 3 && fake.requests[2].token == "02"
        service.registerAppleDeviceToken(Data([2]), accountID: "A", deviceID: "device-1", accessToken: "token-A-refreshed", sessionGeneration: 1)
        await fake.waitUntilCallCount(4)
        let refreshedAccessTokenCompleted = await waitUntilStatus(service, .registered)
        let refreshedAccessToken = refreshedAccessTokenCompleted && fake.requests.count == 4
        service.registerAppleDeviceToken(Data([2]), accountID: "A", deviceID: "device-2", accessToken: "token-A-refreshed", sessionGeneration: 1)
        await fake.waitUntilCallCount(5)
        let deviceChangedCompleted = await waitUntilStatus(service, .registered)
        let deviceChanged = deviceChangedCompleted && fake.requests.count == 5
        service.registerAppleDeviceToken(Data([2]), accountID: "B", deviceID: "device-2", accessToken: "token-B", sessionGeneration: 2)
        await fake.waitUntilCallCount(6)
        let accountChangedCompleted = await waitUntilStatus(service, .registered)
        let accountChanged = accountChangedCompleted && fake.requests.count == 6

        fake.failNext = true
        service.registerAppleDeviceToken(Data([3]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 1)
        await fake.waitUntilCallCount(7)
        let failureObserved = await waitUntilStatus(service, .failed)
        let failed = failureObserved && fake.requests.count == 7 && service.status == .failed
        service.retryCurrentRegistration()
        await fake.waitUntilCallCount(8)
        let retryCompleted = await waitUntilStatus(service, .registered)
        let explicitRetry = retryCompleted && fake.requests.count == 8 && service.status == .registered

        service.registerAppleDeviceToken(Data([4]), accountID: "A", deviceID: "device-1", accessToken: "token-A", sessionGeneration: 2)
        service.clearAuthenticatedSession()
        await settle()
        let obsoleteQueuedDidNotStart = fake.requests.count == 8 && service.status == .disabled

        service.setRegistrationEnabled(true)
        fake.pause = true
        fake.failNext = true
        service.registerAppleDeviceToken(Data([5]), accountID: "B", deviceID: "device-1", accessToken: "token-B", sessionGeneration: 3)
        await fake.waitUntilCallCount(9)
        service.clearAuthenticatedSession()
        fake.pause = false
        fake.release()
        await settle()
        let lateCompletionInert = fake.requests.count == 9 && service.status == .disabled

        service.setRegistrationEnabled(true)
        service.registerAppleDeviceToken(Data(), accountID: "C", deviceID: "device-1", accessToken: "token-C", sessionGeneration: 4)
        service.registerAppleDeviceToken(Data(repeating: 1, count: 9), accountID: "C", deviceID: "device-1", accessToken: "token-C", sessionGeneration: 4)
        service.registerAppleDeviceToken(Data([1]), accountID: " ", deviceID: "device-1", accessToken: "token-C", sessionGeneration: 4)
        await settle()
        let boundedAndAuthenticated = fake.requests.count == 9 && service.status == .idle

        print("default_opt_in_disabled=\(defaultDisabled)")
        print("variable_length_lowercase_hex=\(first) same_tuple_deduplicated=\(deduplicated) dedupe_supersedes_queued_refresh=\(dedupeSupersedesQueued) same_tuple_inflight=\(sameTupleInflight) refreshed_token_compatible=\(refreshedToken) refreshed_access_token=\(refreshedAccessToken) device_changed=\(deviceChanged) account_changed=\(accountChanged)")
        print("failure_requires_explicit_retry=\(failed && explicitRetry) obsolete_queue_did_not_start=\(obsoleteQueuedDidNotStart) late_completion_and_error_inert=\(lateCompletionInert)")
        print("bounded_token_and_authenticated_tuple=\(boundedAndAuthenticated) fake_endpoint_only=true")
        exit(defaultDisabled && first && deduplicated && dedupeSupersedesQueued && sameTupleInflight && refreshedToken && refreshedAccessToken && deviceChanged && accountChanged && failed && explicitRetry && obsoleteQueuedDidNotStart && lateCompletionInert && boundedAndAuthenticated ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vex-push-registration-') as directory:
    directory = Path(directory)
    fixture = directory / 'main.swift'
    binary = directory / 'fixture'
    fixture.write_text(main)
    compile_result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(SOURCE), str(fixture), '-o', str(binary)], text=True, capture_output=True)
    print(compile_result.stdout, end='')
    print(compile_result.stderr, end='', file=sys.stderr)
    if compile_result.returncode:
        raise SystemExit(compile_result.returncode)
    run_result = subprocess.run([str(binary)], text=True, capture_output=True)
    print('source_sha256=' + source_hash)
    print(run_result.stdout, end='')
    print(run_result.stderr, end='', file=sys.stderr)
    raise SystemExit(run_result.returncode)
