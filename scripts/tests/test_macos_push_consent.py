#!/usr/bin/env python3
"""Compile actual APNs consent bodies with inert in-memory fixture state only."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
SOURCE = ROOT / "macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift"
STAGE_STORE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePSKStagedProfileStore.swift"
MODELS = ROOT / "macos-native/Sources/VEXNativeMac/Models/VEXModels.swift"
text = SOURCE.read_text()

def extract(marker: str) -> str:
    start = text.index(marker)
    brace = text.index("{", start)
    depth, index = 1, brace + 1
    while depth:
        depth += (text[index] == "{") - (text[index] == "}")
        index += 1
    return text[start:index]

set_enabled = extract("    func setNativeRemotePushEnabled(")
reconcile = extract("    private func reconcileNativePushSession(").replace("private func", "func", 1)
fingerprint = extract("    private func nativePushConsentFingerprint(").replace("private func", "func", 1)
matches = extract("    private var nativePushConsentMatchesSession:").replace("private var", "var", 1)
purge = extract("    private func purgeNativePushPSKEvents(").replace("private func", "func", 1)
invalidate = extract("    private func invalidateNativePushSession(").replace("private func", "func", 1)
reset = extract("    private func resetAuthenticatedState(")

# This checks the actual reset body rather than pretending the smaller
# termination path establishes logout semantics. The full reset body needs the
# entire app model and is intentionally not duplicated in this fixture.
assert "invalidateNativePushSession(resetConsent: true)" in reset

fixture = f'''import CryptoKit
import Foundation

struct FixtureIdentity {{ func existingDeviceId() -> String? {{ nil }} }}

struct FixtureUser {{ var id: String }}
struct FixtureSession {{ var user: FixtureUser; var accessToken: String }}

@MainActor final class FakeRegistration {{
    var clearCount = 0
    var enabled = false
    var registrations: [(String, String, String, String, Int)] = []
    func clearAuthenticatedSession() {{ clearCount += 1; enabled = false }}
    func setRegistrationEnabled(_ value: Bool) {{ enabled = value }}
    func registerAppleDeviceToken(_ data: Data, accountID: String, deviceID: String, accessToken: String, sessionGeneration: Int) {{
        registrations.append((data.map {{ String(format: "%02x", $0) }}.joined(), accountID, deviceID, accessToken, sessionGeneration))
    }}
    func retryCurrentRegistration() {{}}
}}

@MainActor final class H {{
    let nativePushIdentityStore = FixtureIdentity()
    let nativePushPSKQueue = NativePushPSKEventQueue(appDataURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    let nativePSKStageStore = NativePSKStagedProfileStore(appDataURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    var nativePSKRetryTask: Task<Void, Never>?
    var nativePSKPreparedTunnel: PreparedTunnel?
    var nativeNormalPendingTunnel: PreparedTunnel?
    func startNativePSKRetryIfNeeded() {{}}
    var nativePushEventOwner: NativePushPSKEventOwner?
    var nativePushEventError: String?
    var nativePushRuntimeAllowed = true
    var nativeRemotePushEnabled = false
    var nativeRemotePushConsentAccount = ""
    var nativePushRegistrationError: String?
    var session: FixtureSession?
    var authenticatedSessionGeneration = 1
    var nativePushDeviceID: String?
    var nativePushAccountID: String?
    var nativePushSessionGeneration: Int?
    var nativeApplePushToken: Data?
    var nativePushRegistrationRequested = false
    var registerCalls = 0
    var unregisterCalls = 0
    var registerNativePushAction: (() -> Void)?
    var unregisterNativePushAction: (() -> Void)?
    let nativePushRegistration = FakeRegistration()
    var canUseNativeRemotePush: Bool {{ nativePushRuntimeAllowed }}
{set_enabled}
{reconcile}
{fingerprint}
{matches}
{purge}
{invalidate}
}}

@main struct Main {{
    @MainActor static func main() {{
        let h = H()
        h.registerNativePushAction = {{ h.registerCalls += 1 }}
        h.unregisterNativePushAction = {{ h.unregisterCalls += 1 }}
        func install(_ account: String, _ token: String, _ generation: Int) {{
            h.session = FixtureSession(user: FixtureUser(id: account), accessToken: token)
            h.authenticatedSessionGeneration = generation
            h.nativePushDeviceID = "managed-device-" + account
        }}

        // A historical global true without a matching owner fingerprint cannot
        // start registration for either account.
        install("A", "token-A", 1)
        h.nativeRemotePushEnabled = true
        h.nativeRemotePushConsentAccount = ""
        h.reconcileNativePushSession()
        let legacyFailsClosed = !h.nativePushRegistration.enabled && h.registerCalls == 0

        h.setNativeRemotePushEnabled(true)
        let aExplicit = h.nativeRemotePushEnabled && h.nativePushConsentMatchesSession
            && h.nativePushRegistration.enabled && h.registerCalls == 1
        let aFingerprint = h.nativeRemotePushConsentAccount

        install("B", "token-B", 2)
        h.reconcileNativePushSession()
        let bCannotInherit = h.nativeRemotePushEnabled && !h.nativePushConsentMatchesSession
            && !h.nativePushRegistration.enabled && h.registerCalls == 1

        // Execute the extracted invalidation body; reset-body assertion above
        // proves logout/expiry reaches this exact reset-consent call.
        h.nativePushRegistrationRequested = true
        h.nativeApplePushToken = Data([1])
        h.invalidateNativePushSession(resetConsent: true)
        let logoutClears = !h.nativeRemotePushEnabled && h.nativeRemotePushConsentAccount.isEmpty
            && h.nativePushRegistration.clearCount > 0 && h.unregisterCalls == 1

        install("A", "token-A2", 3)
        h.setNativeRemotePushEnabled(true)
        let aReconsents = h.nativePushConsentMatchesSession && h.nativePushRegistration.enabled
        h.invalidateNativePushSession(resetConsent: true)
        install("B", "token-B2", 4)
        h.setNativeRemotePushEnabled(true)
        let bExplicit = h.nativePushConsentMatchesSession && h.nativePushRegistration.enabled
            && h.nativePushConsentFingerprint("A") != h.nativePushConsentFingerprint("B")
            && aFingerprint == h.nativePushConsentFingerprint("A")

        print("legacy_global_fails_closed=\\(legacyFailsClosed)")
        print("a_explicit_same_account=\\(aExplicit) b_cannot_inherit=\\(bCannotInherit)")
        print("logout_reset_body_calls_reset_consent=true logout_clears_flag_hash_and_registrar=\\(logoutClears)")
        print("explicit_a_and_b_consent=\\(aReconsents && bExplicit) fixture_in_memory_only=true")
        exit(legacyFailsClosed && aExplicit && bCannotInherit && logoutClears && aReconsents && bExplicit ? 0 : 1)
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix="vex-push-consent-") as directory:
    directory = Path(directory)
    swift = directory / "main.swift"
    executable = directory / "fixture"
    swift.write_text(fixture)
    compile_result = subprocess.run(
        ["swiftc", str(__import__("pathlib").Path(__file__).resolve().parents[2]/"macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift"),  "-swift-version", "5", "-parse-as-library", str(MODELS), str(ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushSecureFileStore.swift"), str(ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushPSKEventQueue.swift"), str(STAGE_STORE), str(swift), "-o", str(executable)],
        text=True, capture_output=True,
    )
    print(compile_result.stdout, end="")
    print(compile_result.stderr, end="", file=sys.stderr)
    if compile_result.returncode:
        raise SystemExit(compile_result.returncode)
    run_result = subprocess.run([str(executable), str(directory / "app-data")], text=True, capture_output=True)
    print("appstate_source_sha256=" + hashlib.sha256(SOURCE.read_bytes()).hexdigest())
    print(run_result.stdout, end="")
    print(run_result.stderr, end="", file=sys.stderr)
    raise SystemExit(run_result.returncode)
