#!/usr/bin/env python3
"""Exercise CustomerNotificationService with a fake backend only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos-native/Sources/VEXNativeMac"

harness = r'''
import Foundation

@MainActor
final class FakeBackend: CustomerNotificationBackend {
    var status: CustomerNotificationPermissionStatus = .notDetermined
    var grant = true
    var requestError = false
    var holdAuthorization = false
    var holdFirstAdd = false
    private var authorizationStarted: CheckedContinuation<Void, Never>?
    private var authorizationResume: CheckedContinuation<Void, Never>?
    private var firstAddStarted: CheckedContinuation<Void, Never>?
    private var firstAddResume: CheckedContinuation<Void, Never>?
    var settingsCalls = 0
    var requestCalls = 0
    var added: [CustomerNotificationRequest] = []
    var removed: [String] = []
    func notificationSettings() async -> CustomerNotificationPermissionStatus { settingsCalls += 1; return status }
    func requestAuthorization(options: CustomerNotificationAuthorizationOptions) async throws -> Bool {
        requestCalls += 1
        if holdAuthorization {
            await withCheckedContinuation { continuation in
                authorizationResume = continuation
                authorizationStarted?.resume()
                authorizationStarted = nil
            }
        }
        if requestError { throw URLError(.cannotConnectToHost) }
        return grant
    }
    func add(_ request: CustomerNotificationRequest) async throws {
        added.append(request)
        if holdFirstAdd && added.count == 1 {
            await withCheckedContinuation { continuation in
                firstAddResume = continuation
                firstAddStarted?.resume()
                firstAddStarted = nil
            }
        }
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removed.append(contentsOf: identifiers) }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removed.append(contentsOf: identifiers) }
    func waitForAuthorizationStart() async {
        if authorizationResume != nil { return }
        await withCheckedContinuation { authorizationStarted = $0 }
    }
    func resumeAuthorization() { authorizationResume?.resume(); authorizationResume = nil }
    func waitForFirstAdd() async {
        if firstAddResume != nil { return }
        await withCheckedContinuation { firstAddStarted = $0 }
    }
    func resumeFirstAdd() { firstAddResume?.resume(); firstAddResume = nil }
}

@main
struct Harness {
    static func payload(_ id: String = "vex.activity.support.event") -> CustomerNotificationPayload {
        _ = id
        return .init(title: "Support", body: "Generic")
    }
    @MainActor static func make(_ backend: FakeBackend, _ suffix: String) -> CustomerNotificationService {
        let defaults = UserDefaults(suiteName: "vex-notice-test." + suffix)!
        defaults.removePersistentDomain(forName: "vex-notice-test." + suffix)
        return CustomerNotificationService(defaults: defaults, backendFactory: { backend })
    }
    static func main() async {
        await MainActor.run {
            let backend = FakeBackend()
            let service = make(backend, "default")
            precondition(!service.isEnabled && backend.settingsCalls == 0 && backend.requestCalls == 0)
        }

        let allowed = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized
            return (make(backend, "allowed"), backend)
        }
        await allowed.0.setEnabled(true)
        await allowed.0.deliver([payload()])
        await MainActor.run {
            precondition(allowed.0.isEnabled && allowed.1.requestCalls == 1 && allowed.1.added.count == 1)
        }

        await MainActor.run { allowed.1.status = .denied }
        await allowed.0.refreshAuthorization()
        await MainActor.run {
            precondition(!allowed.0.isEnabled && allowed.1.removed.contains(allowed.1.added[0].identifier))
        }

        let externallyDenied = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized
            return (make(backend, "external-denial"), backend)
        }
        await externallyDenied.0.setEnabled(true)
        await externallyDenied.0.deliver([payload("unnecessary-event-id")])
        await MainActor.run { externallyDenied.1.status = .denied }
        await externallyDenied.0.deliver([payload("another-unnecessary-event-id")])
        await MainActor.run {
            precondition(!externallyDenied.0.isEnabled)
            precondition(externallyDenied.0.permissionStatus == .denied)
            precondition(externallyDenied.1.removed.contains(externallyDenied.1.added[0].identifier))
        }

        let denied = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .denied; backend.grant = false
            return (make(backend, "denied"), backend)
        }
        await denied.0.setEnabled(true); await denied.0.deliver([payload()])
        await MainActor.run { precondition(!denied.0.isEnabled && denied.1.added.isEmpty) }

        let failed = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.requestError = true
            return (make(backend, "failed"), backend)
        }
        await failed.0.setEnabled(true); await failed.0.deliver([payload()])
        await MainActor.run { precondition(!failed.0.isEnabled && failed.1.added.isEmpty) }

        let authorizationRace = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.holdAuthorization = true
            return (make(backend, "authorization-race"), backend)
        }
        let authorization = Task { await authorizationRace.0.setEnabled(true) }
        await authorizationRace.1.waitForAuthorizationStart()
        await authorizationRace.0.setEnabled(false)
        await MainActor.run { authorizationRace.1.resumeAuthorization() }
        _ = await authorization.value
        await MainActor.run { precondition(!authorizationRace.0.isEnabled && !authorizationRace.0.isBusy) }

        let raced = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.holdFirstAdd = true
            return (make(backend, "race"), backend)
        }
        await raced.0.setEnabled(true)
        let delivery = Task { await raced.0.deliver([payload("vex.activity.support.race")]) }
        await raced.1.waitForFirstAdd()
        await raced.0.setEnabled(false)
        await MainActor.run { raced.1.resumeFirstAdd() }
        _ = await delivery.value
        await MainActor.run {
            precondition(!raced.0.isEnabled && raced.1.added.count == 1)
            precondition(raced.1.removed.contains(raced.1.added[0].identifier))
        }

        let reset = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.holdFirstAdd = true
            return (make(backend, "reset"), backend)
        }
        await reset.0.setEnabled(true)
        let resetDelivery = Task { await reset.0.deliver([payload("vex.activity.support.reset")]) }
        await reset.1.waitForFirstAdd()
        await MainActor.run { reset.0.resetSession() }
        await MainActor.run { reset.1.resumeFirstAdd() }
        _ = await resetDelivery.value
        await MainActor.run {
            precondition(reset.1.added.count == 1)
            precondition(reset.1.removed.contains(reset.1.added[0].identifier))
        }

        let epochs = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.holdFirstAdd = true
            return (make(backend, "epochs"), backend)
        }
        await epochs.0.setEnabled(true)
        let old = Task { await epochs.0.deliver([payload("vex.activity.support.same")]) }
        await epochs.1.waitForFirstAdd()
        await MainActor.run { epochs.0.resetSession() }
        await epochs.0.setEnabled(true)
        await epochs.0.deliver([payload("vex.activity.support.same")])
        await MainActor.run { epochs.1.resumeFirstAdd() }
        _ = await old.value
        await MainActor.run {
            precondition(epochs.1.added.count == 2)
            precondition(epochs.1.added[0].identifier != epochs.1.added[1].identifier)
            precondition(!epochs.1.removed.contains(epochs.1.added[1].identifier))
        }

        let eviction = await MainActor.run { () -> (CustomerNotificationService, FakeBackend) in
            let backend = FakeBackend(); backend.status = .authorized; backend.holdFirstAdd = true
            return (make(backend, "eviction"), backend)
        }
        await eviction.0.setEnabled(true)
        let held = Task { await eviction.0.deliver([payload("vex.activity.support.held")]) }
        await eviction.1.waitForFirstAdd()
        for _ in 0...256 { await eviction.0.deliver([payload("vex.activity.support.later")]) }
        await MainActor.run { eviction.1.resumeFirstAdd() }
        _ = await held.value
        await MainActor.run {
            let heldID = eviction.1.added[0].identifier
            precondition(eviction.1.removed.filter { $0 == heldID }.count >= 2)
            let validID = eviction.1.added.last!.identifier
            eviction.0.resetSession()
            precondition(eviction.1.removed.contains(validID))
        }

        let preview = await MainActor.run { () -> (CustomerNotificationService, () -> Bool, () -> Int) in
            var factoryCalls = 0
            let suite = "vex-notice-test.preview"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: CustomerNotificationService.enabledDefaultsKey)
            let service = CustomerNotificationService(defaults: defaults, previewMode: true, backendFactory: {
                factoryCalls += 1
                return FakeBackend()
            })
            return (service, { defaults.bool(forKey: CustomerNotificationService.enabledDefaultsKey) }, { factoryCalls })
        }
        await preview.0.setEnabled(false)
        await preview.0.setEnabled(true)
        await preview.0.refreshAuthorization()
        await preview.0.deliver([payload()])
        await MainActor.run {
            preview.0.resetSession()
            precondition(!preview.0.isEnabled && preview.1() && preview.2() == 0)
        }
        print("PASS: fake notification backend requires opt-in, cancels late delivery, and evicts late add safely")
    }
}
'''

sources = [
    MAC / "Services/CustomerRealtimeService.swift",
    MAC / "Models/CustomerNotificationPolicy.swift",
    MAC / "Services/CustomerNotificationService.swift",
]
with tempfile.TemporaryDirectory(prefix="vex-notification-service-") as directory:
    root = Path(directory)
    source = root / "main.swift"
    source.write_text("\n".join(path.read_text() for path in sources) + "\n" + harness)
    executable = root / "probe"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
