#!/usr/bin/env python3
"""Offline runtime regression for the real macOS customer realtime callbacks."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos-native/Sources/VEXNativeMac"
app_path = Path(os.environ.get("VEX_CALLBACK_APP_SOURCE", MAC / "Stores/VEXAppState.swift"))
app = app_path.read_text()

def body(name: str, next_name: str) -> str:
    start = app.index(name)
    end = app.index(next_name, start)
    return app[start:end].replace("    private func", "    func", 1)

start_realtime = body("    private func startCustomerRealtime(", "    private func resetCustomerNotificationSession(")
reset_notifications = body("    private func resetCustomerNotificationSession(", "    private func refreshCustomerState(")
wire = (MAC / "Services/CustomerRealtimeService.swift").read_text().split("@MainActor\nfinal class CustomerRealtimeService", 1)[0]
policy = (MAC / "Models/CustomerNotificationPolicy.swift").read_text()
notifications = (MAC / "Services/CustomerNotificationService.swift").read_text()

stub = r'''
import Foundation
@MainActor final class FakeBackend: CustomerNotificationBackend {
    var status: CustomerNotificationPermissionStatus = .authorized
    var settingsReads = 0
    var added: [CustomerNotificationRequest] = []
    var removed: [String] = []
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func notificationSettings() async -> CustomerNotificationPermissionStatus { settingsReads += 1; return status }
    func requestAuthorization(options: CustomerNotificationAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: CustomerNotificationRequest) async throws {
        added.append(request)
        let ready = waiters.filter { pair in added.count >= pair.0 }
        waiters.removeAll { pair in added.count >= pair.0 }
        ready.forEach { pair in pair.1.resume() }
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removed += identifiers }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removed += identifiers }
    func waitForAdd(count: Int) async {
        if added.count >= count { return }
        await withCheckedContinuation { continuation in waiters.append((count, continuation)) }
    }
}
@MainActor final class CustomerRealtimeService {
    typealias EventHandler = @MainActor (CustomerRealtimeEvent, CustomerRealtimeMetadata) async -> Void
    typealias StatusHandler = @MainActor (Bool) -> Void
    typealias SessionRejectedHandler = @MainActor () async -> Void
    static var streams: [CustomerRealtimeService] = []
    let onStatus: StatusHandler; let onSessionRejected: SessionRejectedHandler; let onEvent: EventHandler
    init(baseURL: URL, onStatus: @escaping StatusHandler, onSessionRejected: @escaping SessionRejectedHandler, onEvent: @escaping EventHandler) { self.onStatus = onStatus; self.onSessionRejected = onSessionRejected; self.onEvent = onEvent }
    func start(accessToken: String) { Self.streams.append(self) }
    func stop() {}
}
struct User { let id: String }
struct AuthSession { let user: User; let accessToken: String }
struct FakeAPI { let baseURL = URL(string: "https://example.invalid")! }
@MainActor final class Sandbox {
    var session: AuthSession?
    var user: User?
    var customerRealtimeGeneration = 0
    var customerRealtimeService: CustomerRealtimeService?
    var customerFallbackTask: Task<Void, Never>?
    var customerRealtimeConnected = false
    var customerNotificationPolicy = CustomerNotificationPolicy()
    var customerNotificationSessionID: String?
    let backend = FakeBackend()
    lazy var customerNotifications = CustomerNotificationService(defaults: UserDefaults(suiteName: UUID().uuidString)!, backendFactory: { [backend] in backend })
    let api = FakeAPI()
    static let customerFallbackIntervalNanoseconds: UInt64 = 1_000_000_000
    var refreshes = 0
    var refreshRetries = 0
    var refreshHook: (() async -> Void)?
    var accessToken: String? { session?.accessToken }
    func refreshSessionForRetry() async -> String? { refreshRetries += 1; return nil }
    func refreshCustomerState() async {
        refreshes += 1
        if let refreshHook { self.refreshHook = nil; await refreshHook() }
    }
    func start(_ token: String) { startCustomerRealtime(accessToken: token); customerFallbackTask?.cancel() }
'''

main = r'''
}
@main struct Qualification {
    static func event(_ type: String, _ id: String, _ domain: String) -> (CustomerRealtimeEvent, CustomerRealtimeMetadata) {
        let data = "{\"domain\":\"" + domain + "\",\"version\":1}"
        let event = CustomerRealtimeEvent(type: type, id: id, data: data)
        return (event, CustomerRealtimeMetadata.parse(type: type, data: data)!)
    }
    static func drainQueuedMainActorWork() async {
        // Sentinel is submitted after the unstructured delivery Task; awaiting it
        // establishes a MainActor queue boundary without clock-based sleeps.
        await withCheckedContinuation { continuation in
            Task { @MainActor in continuation.resume() }
        }
    }
    static func main() async {
        let app = Sandbox()
        app.session = .init(user: .init(id: "account-a"), accessToken: "token-a")
        app.user = app.session!.user
        await app.customerNotifications.setEnabled(true)
        app.start("token-a")
        let first = CustomerRealtimeService.streams.last!

        let support = event("customer.change", "e1", "support")
        await first.onEvent(support.0, support.1); await app.backend.waitForAdd(count: 1)
        precondition(app.backend.added.count == 1 && !app.backend.added[0].body.contains("e1"))

        // A token/stream refresh in the same account retains notification dedupe.
        app.session = .init(user: .init(id: "account-a"), accessToken: "token-a2")
        app.start("token-a2")
        let second = CustomerRealtimeService.streams.last!; precondition(second !== first)
        let beforeOld = app.refreshes
        first.onStatus(true); await first.onSessionRejected(); await first.onEvent(support.0, support.1)
        precondition(!app.customerRealtimeConnected && app.refreshRetries == 0 && app.refreshes == beforeOld && app.backend.added.count == 1)
        await second.onEvent(support.0, support.1)
        precondition(app.backend.added.count == 1)

        // Resync refreshes customer state, but policy emits no banner.
        let resyncData = "{\"versions\":[{\"domain\":\"support\"},{\"domain\":\"releases\"}]}"
        let resyncEvent = CustomerRealtimeEvent(type: "customer.resync", id: "snapshot", data: resyncData)
        let resync = (resyncEvent, CustomerRealtimeMetadata.parse(type: "customer.resync", data: resyncData)!)
        let beforeResync = app.refreshes
        await second.onEvent(resync.0, resync.1)
        precondition(app.refreshes == beforeResync + 1 && app.backend.added.count == 1)

        // Separate valid support and releases changes create two generic notices.
        let supportSecond = event("customer.change", "e2", "support")
        let releaseSecond = event("customer.change", "e3", "releases")
        await second.onEvent(supportSecond.0, supportSecond.1)
        await second.onEvent(releaseSecond.0, releaseSecond.1); await app.backend.waitForAdd(count: 3)
        precondition(app.backend.added.count == 3)
        precondition(app.backend.added.dropFirst().allSatisfy { request in !request.body.contains("e2") && !request.body.contains("e3") })

        // Rejection clears owned delivery but deliberately retains same-account dedupe.
        await second.onSessionRejected()
        precondition(app.refreshRetries == 1 && !app.backend.removed.isEmpty)
        app.start("token-a2")
        let third = CustomerRealtimeService.streams.last!
        await third.onEvent(supportSecond.0, supportSecond.1)
        precondition(app.backend.added.count == 3)

        // Rejection during the awaited refresh invalidates the queued delivery Task.
        let queued = event("customer.change", "e4", "support")
        app.refreshHook = { await third.onSessionRejected() }
        let settingsBeforeQueuedDelivery = app.backend.settingsReads
        await third.onEvent(queued.0, queued.1)
        await drainQueuedMainActorWork()
        precondition(app.refreshRetries == 2 && app.backend.added.count == 3 && app.backend.settingsReads == settingsBeforeQueuedDelivery)
        app.start("token-a2")
        let fourth = CustomerRealtimeService.streams.last!
        let postRejection = event("customer.change", "e5", "support")
        await fourth.onEvent(postRejection.0, postRejection.1); await app.backend.waitForAdd(count: 4)
        precondition(app.backend.added.count == 4)

        // Account boundary clears requests and policy, then allows new account activity.
        app.session = .init(user: .init(id: "account-b"), accessToken: "token-b")
        app.user = app.session!.user
        let removedBeforeBoundary = app.backend.removed.count
        app.start("token-b")
        let fifth = CustomerRealtimeService.streams.last!
        precondition(app.backend.removed.count > removedBeforeBoundary)
        await fifth.onEvent(support.0, support.1); await app.backend.waitForAdd(count: 5)
        precondition(app.backend.added.count == 5)

        // Revocation clears the new account's owned delivery and retries once.
        let revoked = CustomerRealtimeEvent(type: "customer.session.revoked", id: "", data: "{\"reason\":\"x\"}")
        let removedBeforeRevocation = app.backend.removed.count
        await fifth.onEvent(revoked, CustomerRealtimeMetadata(domains: [], reason: ""))
        precondition(app.refreshRetries == 3 && app.backend.removed.count > removedBeforeRevocation)
        app.customerFallbackTask?.cancel()
        print("PASS: real customer callbacks preserve dedupe and reject stale streams")
        print("PASS: resync, domain fanout, rejection, revocation, and account reset are deterministic")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="vex-customer-callbacks-") as directory:
    source = Path(directory) / "main.swift"
    source.write_text(wire + "\n" + policy + "\n" + notifications + "\n" + stub + start_realtime + reset_notifications + main)
    binary = source.with_name("probe")
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
