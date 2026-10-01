#!/usr/bin/env python3
"""Compile the real refresh guard and assert notification lifecycle wiring offline."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
app_path = ROOT / "macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift"
source = app_path.read_text()
start = source.index("    private func applySessionRefreshResult(")
end = source.index("    private func resolveProfileForAuthenticatedSession(", start)
method = source[start:end].replace("    private func", "    func", 1)
user_start = source.index("    private func loadUser(")
locations_start = source.index("    private func refreshLocations(accessToken", user_start)
billing_start = source.index("    private func loadBilling(", locations_start)
load_user = source[user_start:locations_start].replace("    private func", "    func", 1)
refresh_locations = source[locations_start:billing_start].replace("    private func", "    func", 1)

harness = r'''
import Foundation
struct User: Equatable { let id: String }
struct AuthSession: Equatable { let user: User; let accessToken: String }
struct VpnLocation: Equatable { let id: String }
enum MockFailure: LocalizedError { case failed; var errorDescription: String? { "mock failure" } }
final class FakeAPI {
    var meResult: Result<User, Error> = .failure(MockFailure.failed)
    var locationsResult: Result<[VpnLocation], Error> = .failure(MockFailure.failed)
    var delay: UInt64 = 0
    func me(accessToken: String) async throws -> User { if delay > 0 { try await Task.sleep(nanoseconds: delay) }; return try meResult.get() }
    func vpnLocations(accessToken: String) async throws -> [VpnLocation] { if delay > 0 { try await Task.sleep(nanoseconds: delay) }; return try locationsResult.get() }
}
final class MemorySessionStore {
    var saved: [AuthSession] = []
    func saveSession(_ session: AuthSession, requiresBiometricAuthentication: Bool) throws { saved.append(session) }
}
extension Error { var isUnauthorizedAPIError: Bool { false } }
@MainActor final class RefreshHarness {
    var session: AuthSession?
    var user: User?
    var biometricUnlockRequired = false
    var sessionStore = MemorySessionStore()
    var authError: String?
    var statusMessage: String?
    var streams: [String] = []
    var api = FakeAPI()
    var isLoadingLocations = false
    var locationLoadError: String?
    var locations: [VpnLocation] = []
    var lastLocationsRefreshAt: Date?
    var selectedLocation: VpnLocation? { locations.first { $0.id == selectedLocationId } }
    var selectedLocationId = ""
    var serverSelectionMode = "auto"
    var expired = false
    func startCustomerRealtime(accessToken: String) { streams.append(accessToken) }
    func expireAuthenticatedSession(message: String) { expired = true; session = nil }
    func withSessionRetry<T>(operation: (String) async throws -> T) async -> T? { guard let token = session?.accessToken else { return nil }; return try? await operation(token) }
'''
extra = r'''
    func verifyLateUserAndLocationGuards() async {
        let old = AuthSession(user: .init(id: "old"), accessToken: "old-token")
        let replacement = AuthSession(user: .init(id: "new"), accessToken: "new-token")
        let app = RefreshHarness(); app.session = old; app.user = old.user; app.api.meResult = .success(.init(id: "stale")); app.api.delay = 50_000_000
        let pendingUser = Task { await app.loadUser(old.accessToken) }
        try? await Task.sleep(nanoseconds: 5_000_000); app.session = replacement; app.user = replacement.user
        _ = await pendingUser.value
        precondition(app.user == replacement.user)

        let locations = RefreshHarness(); locations.session = old; locations.api.locationsResult = .failure(MockFailure.failed); locations.api.delay = 50_000_000
        let pendingLocations = Task { await locations.refreshLocations(accessToken: old.accessToken) }
        try? await Task.sleep(nanoseconds: 5_000_000); locations.session = nil
        _ = await pendingLocations.value
        precondition(locations.locations.isEmpty && locations.locationLoadError == nil && locations.statusMessage == nil)

        let current = RefreshHarness(); current.session = old; current.api.meResult = .success(.init(id: "current")); current.api.locationsResult = .success([.init(id: "de")])
        await current.loadUser(old.accessToken); await current.refreshLocations(accessToken: old.accessToken)
        precondition(current.user == .init(id: "current") && current.locations == [.init(id: "de")] && current.selectedLocationId == "de")
    }
'''
tail = r'''
}
@main struct Main {
    static func main() async {
        let old = AuthSession(user: .init(id: "old"), accessToken: "old-token")
        let fresh = AuthSession(user: .init(id: "fresh"), accessToken: "fresh-token")
        let replacement = AuthSession(user: .init(id: "new"), accessToken: "new-token")

        let loggedOut = RefreshHarness(); loggedOut.session = old; loggedOut.session = nil
        let loggedOutResult = await loggedOut.applySessionRefreshResult(.success(fresh), refreshAccessToken: old.accessToken)
        precondition(loggedOutResult == nil && loggedOut.session == nil && loggedOut.sessionStore.saved.isEmpty && loggedOut.streams.isEmpty)

        let switched = RefreshHarness(); switched.session = old; switched.session = replacement
        let switchedResult = await switched.applySessionRefreshResult(.success(fresh), refreshAccessToken: old.accessToken)
        precondition(switchedResult == replacement.accessToken && switched.session == replacement && switched.sessionStore.saved.isEmpty && switched.streams.isEmpty)

        let current = RefreshHarness(); current.session = old
        let currentResult = await current.applySessionRefreshResult(.success(fresh), refreshAccessToken: old.accessToken)
        precondition(currentResult == fresh.accessToken && current.session == fresh && current.sessionStore.saved == [fresh] && current.streams == [fresh.accessToken])
        await current.verifyLateUserAndLocationGuards()
        print("PASS: real loadUser and refreshLocations reject stale late writes")
        print("PASS: real applySessionRefreshResult refuses late old sessions and accepts current refresh")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="vex-realtime-wiring-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness + method + load_user + refresh_locations + extra + tail)
    executable = path.with_name("probe")
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

# Secondary lifecycle checks bind the real callbacks and reset points, but the
# compiler probe above is the regression evidence for the late-refresh guard.
assert "guard session?.accessToken == refreshAccessToken else { return session?.accessToken }" in source
assert "customerRealtimeGeneration == streamGeneration" in source
assert "self.accessToken == accessToken else { return }" in source
assert "customerNotificationPolicy.consume(event: event, metadata: metadata)" in source
assert "await self.customerNotifications.deliver(payloads)" in source
assert "resetCustomerNotificationSession()" in source
assert "customerNotifications.resetSession()" in source
print("PASS: real realtime wiring gates metadata delivery and resets notification session")
