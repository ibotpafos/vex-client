#!/usr/bin/env python3
"""Compiles the production Swift service body with a fake-only async registrar."""
from pathlib import Path
import hashlib, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'macos-native/Sources/VEXNativeMac/Services/NativePushRegistrationService.swift'
if len(sys.argv) == 3 and sys.argv[1] == "--source-root":
    candidate = Path(sys.argv[2])
    SOURCE = candidate / SOURCE.relative_to(ROOT)
elif len(sys.argv) == 2:
    candidate = Path(sys.argv[1])
    SOURCE = candidate / SOURCE.relative_to(ROOT) if candidate.is_dir() else candidate
source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
main = r'''import Combine
import Foundation

struct NativePushRegistrationReceipt: Equatable { let revision: Int64 }

@MainActor final class FakeRegistrar: NativePushRegistrationRegistrar {
    var requests: [NativePushRegistrationRequest] = []
    var unregistered: [NativePushRegistrationRequest] = []
    var failNext = false
    var pause = false
    var nextRevision: Int64 = 1
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func registerNativePush(_ request: NativePushRegistrationRequest) async throws -> NativePushRegistrationReceipt {
        requests.append(request)
        entryContinuation?.resume()
        entryContinuation = nil
        if pause { await withCheckedContinuation { continuation = $0 } }
        if failNext { failNext = false; throw FixtureError.failed }
        defer { nextRevision += 1 }
        return NativePushRegistrationReceipt(revision: nextRevision)
    }
    func unregisterNativePush(_ request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt) async throws { unregistered.append(request) }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilCallCount(_ count: Int) async {
        for _ in 0..<10_000 { if requests.count >= count { return }; await Task.yield() }
    }
}
enum FixtureError: Error { case failed }

@MainActor final class SharedRevisionRegistrar: NativePushRegistrationRegistrar {
    struct Binding { let request: NativePushRegistrationRequest; let revision: Int64 }
    var binding: Binding?
    var nextRevision: Int64 = 1
    var deletes: [(Int64, Bool)] = []
    var throwAfterWrite = false
    var invalidReceipt = false
    func registerNativePush(_ request: NativePushRegistrationRequest) async throws -> NativePushRegistrationReceipt {
        let receipt = NativePushRegistrationReceipt(revision: invalidReceipt ? 0 : nextRevision)
        if !invalidReceipt { binding = Binding(request: request, revision: nextRevision); nextRevision += 1 }
        if throwAfterWrite { throwAfterWrite = false; throw FixtureError.failed }
        return receipt
    }
    func unregisterNativePush(_ request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt) async throws {
        let matches = binding?.request.provider == request.provider && binding?.request.token == request.token && binding?.request.deviceID == request.deviceID && binding?.revision == receipt.revision
        deletes.append((receipt.revision, matches))
        if matches { binding = nil }
    }
}

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

        // Fresh paused registrar proves local disable does not rely on cancellation:
        // the exact old POST finishes, then exactly that tuple is deleted before a new POST.
        let orderingFake = FakeRegistrar()
        let orderingService = NativePushRegistrationService(registrar: orderingFake, maximumTokenBytes: 8)
        orderingService.setRegistrationEnabled(true)
        orderingFake.pause = true
        orderingService.registerAppleDeviceToken(Data([0xaa]), accountID: "old", deviceID: "device-old", accessToken: "auth-old", sessionGeneration: 1)
        await orderingFake.waitUntilCallCount(1)
        orderingService.clearAuthenticatedSession()
        let noDeleteBeforeOldPostCompletes = orderingFake.unregistered.isEmpty && orderingService.status == .disabled
        orderingService.setRegistrationEnabled(true)
        orderingService.registerAppleDeviceToken(Data([0xbb]), accountID: "new", deviceID: "device-new", accessToken: "auth-new", sessionGeneration: 2)
        let newPostHeldBehindOldCleanup = orderingFake.requests.count == 1
        orderingFake.pause = false; orderingFake.release()
        await orderingFake.waitUntilCallCount(2)
        _ = await waitUntilStatus(orderingService, .registered)
        let exactUnregisterAndOrdering = orderingFake.unregistered.count == 1 && orderingFake.unregistered[0].deviceID == "device-old" && orderingFake.unregistered[0].token == "aa" && orderingFake.requests[1].deviceID == "device-new" && orderingFake.requests[1].token == "bb" && orderingService.status == .registered

        let supersedeFake = FakeRegistrar()
        let supersedeService = NativePushRegistrationService(registrar: supersedeFake, maximumTokenBytes: 8)
        supersedeService.setRegistrationEnabled(true)
        supersedeService.registerAppleDeviceToken(Data([0xa1]), accountID: "s", deviceID: "device-s", accessToken: "auth-s", sessionGeneration: 1)
        await supersedeFake.waitUntilCallCount(1); _ = await waitUntilStatus(supersedeService, .registered)
        supersedeFake.pause = true
        supersedeService.registerAppleDeviceToken(Data([0xb2]), accountID: "s", deviceID: "device-s", accessToken: "auth-s", sessionGeneration: 1)
        await supersedeFake.waitUntilCallCount(2)
        // A refreshed callback for the prior successful token is the newest intent.
        supersedeService.registerAppleDeviceToken(Data([0xa1]), accountID: "s", deviceID: "device-s", accessToken: "auth-s", sessionGeneration: 1)
        supersedeFake.pause = false; supersedeFake.release()
        await supersedeFake.waitUntilCallCount(3); _ = await waitUntilStatus(supersedeService, .registered)
        let lateOldCompletionCannotEmptyLatest = supersedeFake.unregistered.count == 1 && supersedeFake.unregistered[0].token == "b2" && supersedeFake.requests[2].token == "a1" && supersedeService.status == .registered

        let queuedFake = FakeRegistrar()
        let queuedService = NativePushRegistrationService(registrar: queuedFake, maximumTokenBytes: 8)
        queuedService.setRegistrationEnabled(true)
        queuedService.registerAppleDeviceToken(Data([0xcc]), accountID: "q", deviceID: "device-q", accessToken: "auth-q", sessionGeneration: 1)
        queuedService.clearAuthenticatedSession()
        await settle()
        let queuedDisableNoPost = queuedFake.requests.isEmpty && queuedFake.unregistered.isEmpty && queuedService.status == .disabled

        // Separate service instances model a process restart: revision 1 cleanup must not clear revision 2.
        let shared = SharedRevisionRegistrar()
        let oldService = NativePushRegistrationService(registrar: shared, maximumTokenBytes: 8)
        oldService.setRegistrationEnabled(true)
        oldService.registerAppleDeviceToken(Data([0xab]), accountID: "same", deviceID: "device-same", accessToken: "auth", sessionGeneration: 1)
        _ = await waitUntilStatus(oldService, .registered)
        let oldReceiptRegistered = shared.binding?.revision == 1
        let newService = NativePushRegistrationService(registrar: shared, maximumTokenBytes: 8)
        newService.setRegistrationEnabled(true)
        newService.registerAppleDeviceToken(Data([0xab]), accountID: "same", deviceID: "device-same", accessToken: "auth", sessionGeneration: 1)
        _ = await waitUntilStatus(newService, .registered)
        let newReceiptRegistered = shared.binding?.revision == 2
        oldService.clearAuthenticatedSession(); await settle(8)
        let oldDeleteMismatchPreservesNew = shared.deletes.first?.0 == 1 && shared.deletes.first?.1 == false && shared.binding?.revision == 2
        newService.clearAuthenticatedSession(); await settle(8)
        let newDeleteExactClears = shared.deletes.count == 2 && shared.deletes[1].0 == 2 && shared.deletes[1].1 && shared.binding == nil

        let noReceiptFake = SharedRevisionRegistrar(); noReceiptFake.throwAfterWrite = true
        let noReceiptService = NativePushRegistrationService(registrar: noReceiptFake, maximumTokenBytes: 8)
        noReceiptService.setRegistrationEnabled(true); noReceiptService.registerAppleDeviceToken(Data([0xcd]), accountID: "x", deviceID: "device-x", accessToken: "auth", sessionGeneration: 1)
        _ = await waitUntilStatus(noReceiptService, .failed); noReceiptService.clearAuthenticatedSession(); await settle(8)
        let ambiguousNoReceiptNoDelete = noReceiptFake.deletes.isEmpty && noReceiptService.status == .disabled

        let invalidReceiptFake = SharedRevisionRegistrar(); invalidReceiptFake.invalidReceipt = true
        let invalidReceiptService = NativePushRegistrationService(registrar: invalidReceiptFake, maximumTokenBytes: 8)
        invalidReceiptService.setRegistrationEnabled(true); invalidReceiptService.registerAppleDeviceToken(Data([0xef]), accountID: "x", deviceID: "device-x", accessToken: "auth", sessionGeneration: 1)
        _ = await waitUntilStatus(invalidReceiptService, .failed); invalidReceiptService.clearAuthenticatedSession(); await settle(8)
        let invalidReceiptNoDelete = invalidReceiptFake.deletes.isEmpty && invalidReceiptService.status == .disabled

        print("revision_cas_old_receipt=\(oldReceiptRegistered) new_receipt=\(newReceiptRegistered) old_delete_preserves_new=\(oldDeleteMismatchPreservesNew) newest_delete_clears=\(newDeleteExactClears) ambiguous_no_receipt_no_delete=\(ambiguousNoReceiptNoDelete) invalid_receipt_no_delete=\(invalidReceiptNoDelete)")
        print("default_opt_in_disabled=\(defaultDisabled)")
        print("variable_length_lowercase_hex=\(first) same_tuple_deduplicated=\(deduplicated) dedupe_supersedes_queued_refresh=\(dedupeSupersedesQueued) same_tuple_inflight=\(sameTupleInflight) refreshed_token_compatible=\(refreshedToken) refreshed_access_token=\(refreshedAccessToken) device_changed=\(deviceChanged) account_changed=\(accountChanged)")
        print("failure_requires_explicit_retry=\(failed && explicitRetry) obsolete_queue_did_not_start=\(obsoleteQueuedDidNotStart) late_completion_and_error_inert=\(lateCompletionInert)")
        print("bounded_token_and_authenticated_tuple=\(boundedAndAuthenticated) queued_disable_no_post=\(queuedDisableNoPost) late_old_completion_reapplies_latest=\(lateOldCompletionCannotEmptyLatest) old_post_then_exact_delete_then_new_post=\(noDeleteBeforeOldPostCompletes && newPostHeldBehindOldCleanup && exactUnregisterAndOrdering) fake_endpoint_only=true")
        exit(defaultDisabled && first && deduplicated && dedupeSupersedesQueued && sameTupleInflight && refreshedToken && refreshedAccessToken && deviceChanged && accountChanged && failed && explicitRetry && obsoleteQueuedDidNotStart && lateCompletionInert && boundedAndAuthenticated && queuedDisableNoPost && lateOldCompletionCannotEmptyLatest && noDeleteBeforeOldPostCompletes && newPostHeldBehindOldCleanup && exactUnregisterAndOrdering && oldReceiptRegistered && newReceiptRegistered && oldDeleteMismatchPreservesNew && newDeleteExactClears && ambiguousNoReceiptNoDelete && invalidReceiptNoDelete ? 0 : 1)
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
