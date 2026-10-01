#!/usr/bin/env python3
"""Offline native-push intake probe using the production receipt body and queue."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
APP = ROOT / "macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift"
SECURE_STORE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushSecureFileStore.swift"
QUEUE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushPSKEventQueue.swift"
STAGE_STORE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePSKStagedProfileStore.swift"
MODELS = ROOT / "macos-native/Sources/VEXNativeMac/Models/VEXModels.swift"
source = APP.read_text()


def extract(signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth, position = 1, brace + 1
    while depth:
        depth += (source[position] == "{") - (source[position] == "}")
        position += 1
    return source[start:position]


# Do not reimplement intake policy in Python: compile this exact production body.
receipt = extract("    func receivedNativeRemoteNotification(_ userInfo: [String: Any])")
purge = extract("    private func purgeNativePushPSKEvents(").replace("private func", "func", 1)
invalidate = extract("    private func invalidateNativePushSession(").replace("private func", "func", 1)
reconcile = extract("    private func reconcileNativePushSession(").replace("private func", "func", 1)
set_enabled = extract("    func setNativeRemotePushEnabled(")
fingerprint = extract("    private func nativePushConsentFingerprint(").replace("private func", "func", 1)
consent_matches = extract("    private var nativePushConsentMatchesSession:").replace("private var", "var", 1)
assert source[source.index(receipt):source.index(receipt) + len(receipt)] == receipt
assert "nativePushPSKQueue.enqueue(event, owner: owner)" in receipt
assert "await self.refreshCustomerState()" in receipt

fixture = f'''import CryptoKit
import Foundation

struct FixtureUser {{ let id: String }}
struct FixtureSession {{ let user: FixtureUser; let accessToken: String }}

final class DisposableIdentityStore {{
    let installationID: String
    init(_ installationID: String) {{ self.installationID = installationID }}
    func getOrCreateDeviceId() -> String {{ installationID }}
    func existingDeviceId() -> String? {{ installationID }}
}}

@MainActor final class RefreshRecorder {{
    private(set) var observations: [Bool] = []
    func record(queue: NativePushPSKEventQueue, owner: NativePushPSKEventOwner) {{
        observations.append((try? queue.events(owner: owner).isEmpty) == false)
    }}
}}

@MainActor final class H {{
    var canUseNativeRemotePush = true
    var nativeRemotePushEnabled = true
    var nativePushConsentMatchesSession = true
    var session: FixtureSession?
    var authenticatedSessionGeneration = 1
    var nativePushDeviceID: String?
    var nativePushEventOwner: NativePushPSKEventOwner?
    var nativePushEventError: String?
    let nativePushIdentityStore: DisposableIdentityStore
    let nativePushPSKQueue: NativePushPSKEventQueue
    let nativePSKStageStore: NativePSKStagedProfileStore
    var nativePSKRetryTask: Task<Void, Never>?
    var nativePSKPreparedTunnel: PreparedTunnel?
    let recorder: RefreshRecorder
    var identityIsCurrent = true

    init(root: URL, recorder: RefreshRecorder) {{
        nativePushIdentityStore = DisposableIdentityStore("install-A")
        nativePushPSKQueue = NativePushPSKEventQueue(appDataURL: root)
        nativePSKStageStore = NativePSKStagedProfileStore(appDataURL: root)
        self.recorder = recorder
    }}

    func ensureAuthenticatedSessionCurrent(generation: Int, accessToken: String, accountID: String) throws -> FixtureSession? {{
        guard identityIsCurrent, generation == authenticatedSessionGeneration,
              let current = session, current.user.id == accountID, current.accessToken == accessToken else {{ return nil }}
        return current
    }}

    func processNativePSKEvents() async {{}}

    func refreshCustomerState() async {{
        guard let session,
              let owner = NativePushPSKEventOwner(accountID: session.user.id, installationID: nativePushIdentityStore.getOrCreateDeviceId()) else {{ return }}
        recorder.record(queue: nativePushPSKQueue, owner: owner)
    }}

{receipt}
}}

func drain() async {{ for _ in 0..<32 {{ await Task.yield() }} }}

@MainActor final class FakeRegistration {{
    func clearAuthenticatedSession() {{}}
    func setRegistrationEnabled(_ enabled: Bool) {{}}
    func registerAppleDeviceToken(_ data: Data, accountID: String, deviceID: String, accessToken: String, sessionGeneration: Int) {{}}
}}
@MainActor final class LifecycleH {{
    var nativePushRuntimeAllowed = true
    var canUseNativeRemotePush = true
    var nativeRemotePushEnabled = false
    var nativeRemotePushConsentAccount = ""
    var nativePushRegistrationError: String?
    var nativePushEventError: String?
    var nativePushEventOwner: NativePushPSKEventOwner?
    var session: FixtureSession?
    var authenticatedSessionGeneration = 1
    var nativePushDeviceID: String?
    var nativePushAccountID: String?
    var nativePushSessionGeneration: Int?
    var nativeApplePushToken: Data?
    var nativePushRegistrationRequested = false
    var registerNativePushAction: (() -> Void)?
    var unregisterNativePushAction: (() -> Void)?
    let nativePushRegistration = FakeRegistration()
    let nativePushIdentityStore = DisposableIdentityStore("install-A")
    let nativePushPSKQueue: NativePushPSKEventQueue
    let nativePSKStageStore: NativePSKStagedProfileStore
    var nativePSKRetryTask: Task<Void, Never>?
    var nativePSKPreparedTunnel: PreparedTunnel?
    func startNativePSKRetryIfNeeded() {{}}
    init(root: URL) {{ nativePushPSKQueue = NativePushPSKEventQueue(appDataURL: root); nativePSKStageStore = NativePSKStagedProfileStore(appDataURL: root) }}
{set_enabled}
{reconcile}
{fingerprint}
{consent_matches}
{purge}
{invalidate}
}}

@main struct Main {{
    static func payload(event: String = "event-1", device: String = "device-A") -> [String: Any] {{
        ["aps": ["content-available": 1], "vex": ["type": "profile_updated", "event_id": event, "rotation_id": "rotation-1", "device_id": device, "profile_version": 7]]
    }}

    @MainActor static func main() async throws {{
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RefreshRecorder()
        let h = H(root: root, recorder: recorder)
        h.session = FixtureSession(user: FixtureUser(id: "account-A"), accessToken: "token-A")
        h.nativePushDeviceID = "device-A"
        let owner = NativePushPSKEventOwner(accountID: "account-A", installationID: "install-A")!

        h.receivedNativeRemoteNotification(payload())
        let persistedBeforeRefresh = (try h.nativePushPSKQueue.events(owner: owner).map(\\.eventID)) == ["event-1"]
        await drain()
        let validRefresh = recorder.observations == [true]

        h.receivedNativeRemoteNotification(payload())
        await drain()
        let deduped = try h.nativePushPSKQueue.events(owner: owner).map(\\.eventID) == ["event-1"]
        let restarted = try NativePushPSKEventQueue(appDataURL: root).events(owner: owner).map(\\.eventID) == ["event-1"]
        let dedupedAndRestarted = deduped && restarted

        let refreshBeforeRejects = recorder.observations.count
        h.receivedNativeRemoteNotification(payload(event: "wrong-device", device: "other"))
        h.receivedNativeRemoteNotification(["aps": ["content-available": 1], "vex": ["type": "profile_updated", "event_id": "bad", "rotation_id": "r", "device_id": "device-A", "profile_version": true]])
        h.canUseNativeRemotePush = false; h.receivedNativeRemoteNotification(payload(event: "no-capability")); h.canUseNativeRemotePush = true
        h.nativeRemotePushEnabled = false; h.receivedNativeRemoteNotification(payload(event: "no-enabled")); h.nativeRemotePushEnabled = true
        h.nativePushConsentMatchesSession = false; h.receivedNativeRemoteNotification(payload(event: "no-consent")); h.nativePushConsentMatchesSession = true
        h.session = nil; h.receivedNativeRemoteNotification(payload(event: "no-session")); h.session = FixtureSession(user: FixtureUser(id: "account-A"), accessToken: "token-A")
        await drain()
        let rejectedReceipts = (try h.nativePushPSKQueue.events(owner: owner).map(\\.eventID)) == ["event-1"] && recorder.observations.count == refreshBeforeRejects

        h.receivedNativeRemoteNotification(["aps": ["content-available": 1]])
        await drain()
        let apsOnlyRefresh = recorder.observations.count == refreshBeforeRejects + 1

        // The production Task guard must suppress refresh if identity changes after receipt.
        h.receivedNativeRemoteNotification(payload(event: "late-identity"))
        h.session = FixtureSession(user: FixtureUser(id: "account-B"), accessToken: "token-B")
        let newOwner = NativePushPSKEventOwner(accountID: "account-B", installationID: "install-A")!
        await drain()
        let oldOwnerEvents = try h.nativePushPSKQueue.events(owner: owner).map(\\.eventID)
        let newOwnerEvents = try h.nativePushPSKQueue.events(owner: newOwner)
        let lateIdentityNoRefresh = recorder.observations.count == refreshBeforeRejects + 1
            && oldOwnerEvents == ["event-1", "late-identity"] && newOwnerEvents.isEmpty
        h.session = FixtureSession(user: FixtureUser(id: "account-A"), accessToken: "token-A")

        let errorRoot = root.appendingPathComponent("error-root", isDirectory: true)
        try fm.createDirectory(at: errorRoot, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: errorRoot.appendingPathComponent("push-psk-events"), withDestinationURL: outside)
        let errorRecorder = RefreshRecorder(); let broken = H(root: errorRoot, recorder: errorRecorder)
        broken.session = h.session; broken.nativePushDeviceID = "device-A"
        broken.receivedNativeRemoteNotification(payload(event: "write-error")); await drain()
        let outsideEmpty = try fm.contentsOfDirectory(atPath: outside.path).isEmpty
        let filesystemErrorFailsClosed = errorRecorder.observations == [false]
            && broken.nativePushEventError == "Не удалось сохранить событие смены ключей. Профиль не применён."
            && outsideEmpty

        let lifecycleRoot = root.appendingPathComponent("lifecycle", isDirectory: true)
        try fm.createDirectory(at: lifecycleRoot, withIntermediateDirectories: true)
        let lifecycle = LifecycleH(root: lifecycleRoot)
        lifecycle.session = FixtureSession(user: FixtureUser(id: "account-A"), accessToken: "token-A")
        lifecycle.setNativeRemotePushEnabled(true)
        lifecycle.nativePushEventOwner = owner
        _ = try lifecycle.nativePushPSKQueue.enqueue(NativePushPSKEvent(kind: .profile_updated, eventID: "disable", rotationID: "r", deviceID: "device-A", profileVersion: 1, deadlineAt: nil), owner: owner)
        lifecycle.setNativeRemotePushEnabled(false)
        let explicitDisablePurges = try lifecycle.nativePushPSKQueue.events(owner: owner).isEmpty
        lifecycle.nativeRemotePushEnabled = true; lifecycle.nativePushEventOwner = owner
        _ = try lifecycle.nativePushPSKQueue.enqueue(NativePushPSKEvent(kind: .profile_updated, eventID: "logout", rotationID: "r", deviceID: "device-A", profileVersion: 1, deadlineAt: nil), owner: owner)
        lifecycle.invalidateNativePushSession(resetConsent: true)
        let logoutPurges = try lifecycle.nativePushPSKQueue.events(owner: owner).isEmpty
        _ = try lifecycle.nativePushPSKQueue.enqueue(NativePushPSKEvent(kind: .profile_updated, eventID: "restart", rotationID: "r", deviceID: "device-A", profileVersion: 1, deadlineAt: nil), owner: owner)
        lifecycle.invalidateNativePushSession(resetConsent: false)
        let terminationRetains = try lifecycle.nativePushPSKQueue.events(owner: owner).map(\.eventID) == ["restart"]
        let previewRoot = root.appendingPathComponent("preview-no-fs", isDirectory: true)
        let preview = LifecycleH(root: previewRoot); preview.nativePushRuntimeAllowed = false; preview.purgeNativePushPSKEvents()
        let previewNoFilesystem = !fm.fileExists(atPath: previewRoot.path)

        print("source_intake_body=true queue_source_runtime=true")
        print("synchronous_persistence_before_refresh=\\(persistedBeforeRefresh && validRefresh)")
        print("durable_dedupe_restart=\\(dedupedAndRestarted) rejected_metadata_capability_consent_session=\\(rejectedReceipts)")
        print("aps_only_generic_refresh=\\(apsOnlyRefresh) late_identity_no_refresh=\\(lateIdentityNoRefresh) filesystem_error_generic_refresh=\\(filesystemErrorFailsClosed)")
        print("disable_logout_purge=\\(explicitDisablePurges && logoutPurges) termination_retains=\\(terminationRetains) preview_no_filesystem=\\(previewNoFilesystem)")
        exit(persistedBeforeRefresh && validRefresh && dedupedAndRestarted && rejectedReceipts && apsOnlyRefresh && lateIdentityNoRefresh && filesystemErrorFailsClosed && explicitDisablePurges && logoutPurges && terminationRetains && previewNoFilesystem ? 0 : 1)
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix="vex-native-push-intake-", dir="/private/tmp") as directory:
    directory = Path(directory)
    app_data = directory / "app-data"
    main = directory / "main.swift"
    binary = directory / "probe"
    main.write_text(fixture)
    compiled = subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(MODELS), str(SECURE_STORE), str(QUEUE), str(STAGE_STORE), str(main), "-o", str(binary)], text=True, capture_output=True)
    print(compiled.stdout, end="")
    print(compiled.stderr, end="", file=sys.stderr)
    print("appstate_source_sha256=" + hashlib.sha256(APP.read_bytes()).hexdigest())
    print("secure_store_source_sha256=" + hashlib.sha256(SECURE_STORE.read_bytes()).hexdigest())
    print("queue_source_sha256=" + hashlib.sha256(QUEUE.read_bytes()).hexdigest())
    if compiled.returncode:
        raise SystemExit(compiled.returncode)
    ran = subprocess.run([str(binary), str(app_data)], text=True, capture_output=True)
    print(ran.stdout, end="")
    print(ran.stderr, end="", file=sys.stderr)
    raise SystemExit(ran.returncode)
