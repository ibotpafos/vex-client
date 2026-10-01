#!/usr/bin/env python3
"""Offline runtime gate: execute the extracted production PSK cutover body only.

The generated Swift fixture has inert collaborators: it cannot launch the app,
helper, VPN, routes, DNS, PF, API, APNs, Keychain, or preferences.
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
source = root / "macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift"
records = Path("/Volumes/D/Projects/mobile/macos-release-transaction-20261001")
records.mkdir(parents=True, exist_ok=True)

def extract(name: str) -> str:
    text = source.read_text()
    start = text.index(f"    private func {name}(")
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += (text[i] == "{") - (text[i] == "}")
        if depth == 0:
            return text[start:i + 1]
    raise AssertionError(f"unterminated {name}")

# This is deliberately the byte-for-byte production method, not a reimplementation.
cutover = extract("applyNativePSKCutover")
fixture = r'''import Foundation

enum AuthenticatedOperationError: Error { case sessionChanged }
enum Desired { case connected, disconnected }
struct Owner { let accountID: String }; typealias NativePushPSKEventOwner = Owner
struct Device: Equatable { let id: String }
enum Routing: String { case full }; struct PreparedTunnel: Equatable { let id: String; let device: Device; let locationId: String; let routingMode: Routing; let bypassRegion: String? }
struct PSKRotationCurrentResponse { let version: Int }
struct Entitlement { var hasPaidAccess: Bool }
struct Verified { let envelope: PSKRotationCurrentResponse }
@MainActor final class Verifier { func verifyDetailed(_ e: PSKRotationCurrentResponse, ownerAccountID: String, managedDeviceID: String, locationID: String, routingMode: String, bypassRegion: String?) throws -> Verified { .init(envelope: e) } }
struct Status { var isUsableConnectedStatus = false; var hasManagedNetworkState = false; var endpoint = "" }
@MainActor final class VEXHelperModel { var status = Status(); var hasConfirmedIdleStatus = false; var isBusy = false; var lastConnectAdmissionRejected = false }
@MainActor final class Profile {
  unowned let app: AppState; var prepares = 0; var promotions = 0
  init(_ app: AppState) { self.app = app }
  func prepareStagedPSKProfile(_ verified: Verified, basedOn old: PreparedTunnel) throws -> PreparedTunnel { prepares += 1; return .init(id: "next", device: old.device, locationId: old.locationId, routingMode: old.routingMode, bypassRegion: old.bypassRegion) }
  func promoteStagedPSKProfile(_ t: PreparedTunnel, owner: Owner) throws { promotions += 1; if app.mode == .promotionThrows { throw FixtureError.boom } }
}
enum FixtureError: Error { case boom }
enum Mode { case success, connectThrows, promotionThrows, sessionChanges, tokenChanges, accountChanges, vpnGenerationChanges, accessRevoked }
@MainActor final class AppState {
  var activeTunnel: PreparedTunnel?; var desiredVpnState: Desired = .connected; var vpnOperationGeneration = 10
  var activeResiliencePolicy = "old-policy"; var activeResilienceRoute = "old-route"; var isVpnBusy = false; var isDeviceBusy = false
  var nativePSKPreparedTunnel: PreparedTunnel?; var nativePushEventError: String?; var antiLeakEnabled = true
  var entitlement: Entitlement? = .init(hasPaidAccess: true); var authenticatedSessionGeneration = 4; var token = "token"; var account = "account"; var mode: Mode = .success; var connects = 0; var releaseFlags: [Bool] = []; var endpointFallbackFlags: [Bool] = []
  lazy var profileService = Profile(self); let nativePSKVerifier = Verifier()
  func ensureAuthenticatedSessionCurrent(generation: Int, accessToken: String? = nil, accountID: String? = nil) throws { guard generation == authenticatedSessionGeneration, accessToken.map({ $0 == token }) ?? true, accountID.map({ $0 == account }) ?? true else { throw AuthenticatedOperationError.sessionChanged } }
  func ensureConnectStillDesired(generation: Int, sessionGeneration: Int? = nil, accessToken: String? = nil, accountID: String? = nil) throws { if let sessionGeneration { try ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: accessToken, accountID: accountID) }; guard desiredVpnState == .connected, vpnOperationGeneration == generation else { throw CancellationError() } }
  func tunnel(_ t: PreparedTunnel, matches status: Status) -> Bool { t.id == status.endpoint }
  func connectPreparedTunnel(_ t: PreparedTunnel, helper: VEXHelperModel, generation: Int, sessionGeneration: Int, accessToken: String, accountID: String, releaseAntiLeakOnFailure: Bool, allowEndpointFallback: Bool = true) async throws -> PreparedTunnel { connects += 1; releaseFlags.append(releaseAntiLeakOnFailure); endpointFallbackFlags.append(allowEndpointFallback); switch mode { case .connectThrows: throw FixtureError.boom; case .sessionChanges: authenticatedSessionGeneration += 1; case .tokenChanges: token = "other"; case .accountChanges: account = "other"; case .vpnGenerationChanges: vpnOperationGeneration += 1; case .accessRevoked: entitlement?.hasPaidAccess = false; default: break }; return t }
'''+cutover+r'''
  func testApplyNativePSKCutover(_ envelope: PSKRotationCurrentResponse, previous: PreparedTunnel, owner: NativePushPSKEventOwner, helper: VEXHelperModel, sessionGeneration: Int, token: String) async throws -> Int { try await applyNativePSKCutover(envelope, previous: previous, owner: owner, helper: helper, sessionGeneration: sessionGeneration, token: token) }
}
@main struct Main {
 @MainActor static func main() async {
  var failed = 0
  func base(_ connected: Bool = false) -> (AppState, VEXHelperModel, PreparedTunnel, Owner) { let a = AppState(); let p = PreparedTunnel(id: "old", device: .init(id:"device"), locationId:"loc", routingMode:.full, bypassRegion:nil); a.activeTunnel = p; let h = VEXHelperModel(); h.status = .init(isUsableConnectedStatus: connected, hasManagedNetworkState:false, endpoint:"old"); return (a,h,p,.init(accountID:"account")) }
  func expect(_ name: String, _ ok: Bool) { print("\(name)=\(ok ? "PASS" : "FAIL")"); if !ok { failed += 1 } }
  do { let (a,h,p,o)=base(); h.hasConfirmedIdleStatus=true; _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("confirmed_idle_cache_only", a.activeTunnel?.id == "next" && a.connects == 0 && a.profileService.promotions == 1) } catch { expect("confirmed_idle_cache_only",false) }
  for (name, setup) in [("unconfirmed_idle", { (h: VEXHelperModel) in }), ("managed_idle", { (h: VEXHelperModel) in h.hasConfirmedIdleStatus=true; h.status.hasManagedNetworkState=true })] { let (a,h,p,o)=base(); setup(h); do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect(name,false) } catch { expect(name,a.connects == 0 && a.profileService.promotions == 0) } }
  for (name, entitlement) in [("nil_paid_access", Optional<Entitlement>.none), ("revoked_paid_access", Optional(Entitlement(hasPaidAccess: false)))] { let (a,h,p,o)=base(true); a.entitlement = entitlement; do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect(name,false) } catch { expect(name,a.connects == 0 && a.profileService.prepares == 0 && a.profileService.promotions == 0) } }
  do { let (a,h,p,o)=base(true); a.activeTunnel = .init(id:"external",device:p.device,locationId:p.locationId,routingMode:.full,bypassRegion:nil); do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("external_active_rejected",false) } catch { expect("external_active_rejected",a.connects == 0 && a.profileService.promotions == 0) } }
  do { let (a,h,p,o)=base(true); _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("connected_owned",a.activeTunnel?.id == "next" && a.connects == 1 && a.releaseFlags == [false] && a.endpointFallbackFlags == [false] && a.profileService.promotions == 1) } catch { expect("connected_owned",false) }
  do { let (a,h,p,o)=base(true); a.mode = .connectThrows; do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("throwing_connect_rollback",false) } catch { expect("throwing_connect_rollback",a.activeTunnel == p && a.connects == 2 && a.releaseFlags.allSatisfy { !$0 } && a.endpointFallbackFlags.allSatisfy { !$0 }) } }
  for mode in [Mode.sessionChanges,.tokenChanges,.accountChanges,.vpnGenerationChanges] { let (a,h,p,o)=base(true); a.mode=mode; do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("stale_\(mode)",false) } catch { expect("stale_\(mode)",a.profileService.promotions == 0 && a.connects == 1 && a.activeTunnel == p && a.nativePushEventError == nil) } }
  do { let (a,h,p,o)=base(true); a.mode = .accessRevoked; do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("inflight_paid_access_revoked",false) } catch { expect("inflight_paid_access_revoked",a.profileService.promotions == 0 && a.connects == 1 && a.activeTunnel == p && a.nativePushEventError == nil) } }
  do { let (a,h,p,o)=base(true); a.mode = .promotionThrows; do { _=try await a.testApplyNativePSKCutover(.init(version:1),previous:p,owner:o,helper:h,sessionGeneration:4,token:"token"); expect("throwing_promotion",false) } catch { expect("throwing_promotion",a.activeTunnel == p && a.connects == 2 && a.nativePushEventError != nil) } }
  exit(failed == 0 ? 0 : 1)
 }
}
'''
with tempfile.TemporaryDirectory(prefix="vex-cutover-runtime-") as d:
    p = Path(d); swift = p / "cutover.swift"; binary = p / "cutover"; swift.write_text(fixture)
    compile = subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], text=True, capture_output=True)
    run = subprocess.run([str(binary)], text=True, capture_output=True) if compile.returncode == 0 else None
    log = (f"source={source}\ncommand=swiftc -swift-version 5 -parse-as-library {swift} -o {binary}\ncompile_exit={compile.returncode}\ncompile_stdout:\n{compile.stdout}\ncompile_stderr:\n{compile.stderr}\n" + (f"command={binary}\nrun_exit={run.returncode}\nrun_stdout:\n{run.stdout}\nrun_stderr:\n{run.stderr}\n" if run else ""))
    (records / "cycle-11-cutover-runtime.log").write_text(log)
    (records / "cycle-11-cutover-runtime.swift").write_text(fixture)
    print(compile.stdout, end=""); print(compile.stderr, end="", file=sys.stderr)
    if run: print(run.stdout, end=""); print(run.stderr, end="", file=sys.stderr)
    raise SystemExit(compile.returncode or (run.returncode if run else 1))
