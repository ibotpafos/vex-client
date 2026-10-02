#!/usr/bin/env python3
"""Actual PSK app body, helper wrapper and coordinator, with inert RPC/config ports.

Optional source root supports the identical baseline/modified/rollback gate.
No installed helper, app, networking, Keychain, API or APNs is invoked. Evidence
goes to stdout/stderr rather than overwriting historical cycle-11 records.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"


def extract(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


cutover = extract((S / "Stores/VEXAppState.swift").read_text(), "    private func applyNativePSKCutover(")
helper_source = (S / "VEXHelperClient.swift").read_text()
wrapper = extract(helper_source, "    func replaceProfilePreservingProtection(") if "    func replaceProfilePreservingProtection(" in helper_source else ""
revalidate = extract(helper_source, "    func revalidateProtectedCommit(") if "    func revalidateProtectedCommit(" in helper_source else """
    func revalidateProtectedCommit(_ receipt: NativeProtectedReplacementCoordinator.Receipt,
        isCurrent: @escaping () -> Bool) async throws { throw FixtureError.boom }
"""
coordinator = S / "Services/NativeProtectedReplacementCoordinator.swift"
store = S / "Services/NativeAdmittedProfileStore.swift"
app_source = (S / "Stores/VEXAppState.swift").read_text()
scope_body = extract(app_source, "    private func nativeAdmittedProfileScope(") if "    private func nativeAdmittedProfileScope(" in app_source else """
    private func nativeAdmittedProfileScope(for tunnel:PreparedTunnel) throws -> NativeAdmittedProfileStore.Scope {
        .init(accountID: account,installationID: "installation",sessionGeneration: authenticatedSessionGeneration)
    }
"""
LEGACY_STORE_FIXTURE = '\n@MainActor final class NativeAdmittedProfileStore {\n struct Scope: Equatable { let accountID:String; let installationID:String; let sessionGeneration:Int }\n struct Source { let revision=UUID();let tunnel:PreparedTunnel;let canonicalConfig:String;let ownerTokenSHA256:String;let scope:Scope }\n enum Failure:Error { case staleSource }\n private var value:Source?; private weak var helper:AnyObject?\n @discardableResult func record(tunnel:PreparedTunnel,canonicalConfig:String,ownerTokenSHA256:String,scope:Scope,helper:AnyObject)throws->Source { let v=Source(tunnel:tunnel,canonicalConfig:canonicalConfig,ownerTokenSHA256:ownerTokenSHA256,scope:scope);value=v;self.helper=helper;return v }\n func source(for tunnel:PreparedTunnel,scope:Scope,helper:AnyObject)throws->Source { guard let v=value,v.tunnel==tunnel,v.scope==scope,self.helper === helper else {throw Failure.staleSource};return v }\n func isCurrent(_ source:Source,scope:Scope,helper:AnyObject)->Bool { (try? self.source(for:source.tunnel,scope:scope,helper:helper).revision)==source.revision }\n func clear(){value=nil;helper=nil}\n}\n'
HARNESS = r'''
import Foundation
import CryptoKit
enum AuthenticatedOperationError: Error { case sessionChanged }
enum Desired { case connected, disconnected }
struct Owner: Equatable { let accountID: String; var installationID="installation" }; typealias NativePushPSKEventOwner = Owner
struct User { let id:String }; struct Session { let user:User; let accessToken:String }
@MainActor final class Identity { var value:String?="installation";func existingDeviceId()->String? {value} }
struct Device: Equatable { let id: String; var externalDeviceId:String?="installation" }
enum Routing: String { case full, split }
struct PreparedTunnel: Equatable {
 let id: String; let device: Device; let locationId: String
 let routingMode: Routing; let bypassRegion: String?
}
struct PSKRotationCurrentResponse { let version: Int }
struct Entitlement { var hasPaidAccess: Bool }
struct Verified { let envelope: PSKRotationCurrentResponse }
@MainActor final class Verifier {
 func verifyDetailed(_ e: PSKRotationCurrentResponse, ownerAccountID: String, managedDeviceID: String, locationID: String, routingMode: String, bypassRegion: String?) throws -> Verified { .init(envelope: e) }
}
struct Status { var isUsableConnectedStatus=false; var hasManagedNetworkState=false; var endpoint="" }
enum FixtureError: Error { case boom }
enum Mode { case commitReplyLost, success, connectThrows, promotionThrows, sessionChanges, tokenChanges, accountChanges, vpnGenerationChanges, accessRevoked, selectionChanges, routingChanges, helperChanges, snapshotThrows, snapshotOwnerChanges, snapshotCandidateChanges, snapshotJournal, snapshotScopeChanges }
@MainActor final class Client {
 unowned let app: AppState
 let id="E63DCEBD-109A-4C45-A23C-3F32BF42597A"
 var replacements=0, commits=0, recoveries=0, snapshots=0, journal=false
 init(_ app: AppState) { self.app=app }
 func digest(_ value: String)->String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
 func send(_ command:String, timeoutSeconds:Int) async throws -> String {
  let source=digest("old-profile"), candidate=digest("next-profile"), owner=digest("fixture-owner")
  switch command.split(separator:" ").first {
  case "protected-snapshot":
   snapshots += 1
   if commits > 0 && app.mode == .snapshotThrows { throw FixtureError.boom }
   if commits > 0 && app.mode == .snapshotScopeChanges { app.authenticatedSessionGeneration += 1 }
   let observed = commits > 0 && app.mode != .snapshotCandidateChanges ? candidate : source
   let observedOwner = (app.foreignOwner || (commits > 0 && app.mode == .snapshotOwnerChanges)) ? digest("foreign-owner") : owner
   let pending = journal || (commits > 0 && app.mode == .snapshotJournal)
   return "protected_protocol=1 recovery_pending=\(pending) source_sha256=\(observed) owner_token_sha256=\(observedOwner) transaction_id=\(id)" + (pending ? " candidate_sha256=\(candidate)" : "") + (app.mode == .commitReplyLost ? " commit_receipt_protocol=1" : "") + "\n"
  case "protected-replace":
   replacements += 1; journal=true; try app.boundary()
   return "ready transaction_id=\(id) candidate_sha256=\(candidate)\n"
  case "protected-commit":
   commits += 1; journal=false
   if app.mode == .commitReplyLost {throw FixtureError.boom}
   return "committed transaction_id=\(id) candidate_sha256=\(candidate) latest_handshake=100\n"
  case "protected-receipt":
   guard app.mode == .commitReplyLost,commits==1,!journal else {throw FixtureError.boom}
   return "committed commit_receipt_protocol=1 transaction_id=\(id) source_sha256=\(source) candidate_sha256=\(candidate) owner_token_sha256=\(owner) latest_handshake=100\n"
  case "protected-recover":
   recoveries += 1; journal=false
   return "recovered transaction_id=\(id)\n"
  default: throw FixtureError.boom
  }
 }
}
@MainActor final class VEXHelperModel {
 var status=Status(), hasConfirmedIdleStatus=false, isBusy=false, lastConnectAdmissionRejected=false
 var canUseExistingValidatedHelper=true
 let client: Client
 private let protectedReplacement=NativeProtectedReplacementCoordinator()
 var hasPendingProtectedReplacement: Bool { protectedReplacement.hasPendingTransaction }
 init(_ app: AppState) { client=Client(app) }
 func refreshStatus(quiet: Bool) async -> Bool { true }
 WRAPPER
 REVALIDATE
}
@MainActor final class Profile {
 unowned let app: AppState
 var prepares=0, promotions=0, writes=0, sourcePrepares=0, candidatePrepares=0;var sourceDNSChanged=false
 init(_ app: AppState) { self.app=app }
 func prepareStagedPSKProfile(_ verified: Verified, basedOn old: PreparedTunnel) throws -> PreparedTunnel {
  prepares += 1
  return .init(id:"next",device:old.device,locationId:old.locationId,routingMode:old.routingMode,bypassRegion:old.bypassRegion)
 }
 func prepareProtectedHelperConfig(for tunnel: PreparedTunnel, validateCurrent: @MainActor () throws -> Void) async throws -> String {
  try validateCurrent(); await Task.yield(); try validateCurrent(); if tunnel.id=="old" {sourcePrepares+=1;return sourceDNSChanged ? "rotated-DNS-profile" : "old-profile"};candidatePrepares+=1;return tunnel.id + "-profile"
 }
 func stageProtectedHelperConfig(_ config:String, validateCurrent: @MainActor () throws -> Void) throws { try validateCurrent(); writes += 1 }
 func promoteStagedPSKProfile(_ t: PreparedTunnel, owner: Owner) throws {
  promotions += 1; if app.mode == .promotionThrows { throw FixtureError.boom }
 }
}
@MainActor final class AppState {
 var activeTunnel: PreparedTunnel?, nativePSKPreparedTunnel: PreparedTunnel?
 var nativePSKCommittedPromotion: (source:PreparedTunnel,candidate:PreparedTunnel,owner:NativePushPSKEventOwner,
   receipt:NativeProtectedReplacementCoordinator.Receipt,generation:Int,isCurrent:@MainActor ()->Bool)?
 var desiredVpnState: Desired = .connected, vpnOperationGeneration=10
 var activeResiliencePolicy:String?="old-policy", activeResilienceRoute:String?="old-route"
 var isVpnBusy=false, isDeviceBusy=false, antiLeakEnabled=true
 var nativePushEventError:String?, nativePSKHelper:VEXHelperModel?
 var selectedLocationId="loc", targetLocationId:String?="loc", routingMode:Routing = .full
 var entitlement:Entitlement? = .init(hasPaidAccess:true), authenticatedSessionGeneration=4
 var token="token", account="account", mode:Mode = .success, connects=0
 var releaseFlags:[Bool]=[], endpointFallbackFlags:[Bool]=[]
 var foreignOwner=false
 var session:Session? { .init(user:.init(id:account),accessToken:token) }
 let nativePushIdentityStore=Identity(), nativeAdmittedProfiles=NativeAdmittedProfileStore()
 SCOPE_BODY
 lazy var profileService=Profile(self)
 let nativePSKVerifier=Verifier()
 func ensureAuthenticatedSessionCurrent(generation:Int, accessToken:String?=nil, accountID:String?=nil) throws {
  guard generation==authenticatedSessionGeneration, accessToken.map({ $0==token }) ?? true, accountID.map({ $0==account }) ?? true else { throw AuthenticatedOperationError.sessionChanged }
 }
 func ensureConnectStillDesired(generation:Int, sessionGeneration:Int?=nil, accessToken:String?=nil, accountID:String?=nil) throws {
  if let sessionGeneration { try ensureAuthenticatedSessionCurrent(generation:sessionGeneration,accessToken:accessToken,accountID:accountID) }
  guard desiredVpnState == .connected, vpnOperationGeneration==generation else { throw CancellationError() }
 }
 func tunnel(_ t:PreparedTunnel,matches status:Status)->Bool { t.id==status.endpoint }
 func boundary() throws {
  switch mode {
  case .connectThrows: throw FixtureError.boom
  case .sessionChanges: authenticatedSessionGeneration += 1
  case .tokenChanges: token="other"
  case .accountChanges: account="other"
  case .vpnGenerationChanges: vpnOperationGeneration += 1
  case .accessRevoked: entitlement?.hasPaidAccess=false
  case .selectionChanges: selectedLocationId="other"
  case .routingChanges: routingMode = .split
  case .helperChanges: nativePSKHelper=nil
  default: break
  }
 }
 // Legacy source uses this inert port; the modified source must never reach it.
 func connectPreparedTunnel(_ t:PreparedTunnel,helper:VEXHelperModel,generation:Int,sessionGeneration:Int,accessToken:String,accountID:String,releaseAntiLeakOnFailure:Bool,allowEndpointFallback:Bool=true) async throws -> PreparedTunnel {
  connects += 1; releaseFlags.append(releaseAntiLeakOnFailure); endpointFallbackFlags.append(allowEndpointFallback); try boundary(); return t
 }
 CUTOVER
 func nativeAdmittedProfileScopeForFixture(_ tunnel:PreparedTunnel) throws -> NativeAdmittedProfileStore.Scope {try nativeAdmittedProfileScope(for:tunnel)}
 func run(_ previous:PreparedTunnel,_ helper:VEXHelperModel) async throws -> Int {
  try await applyNativePSKCutover(.init(version:1),previous:previous,owner:.init(accountID:"account"),helper:helper,sessionGeneration:4,token:"token")
 }
 func retry(_ helper:VEXHelperModel) async throws -> Int {
  try await run(nativePSKCommittedPromotion?.source ?? activeTunnel!,helper)
 }
}
@main struct Main {
 @MainActor static func main() async {
  var cases=0, failures=0
  func base(_ connected:Bool=false)->(AppState,VEXHelperModel,PreparedTunnel) {
   let a=AppState(), h:VEXHelperModel
   let p=PreparedTunnel(id:"old",device:.init(id:"device"),locationId:"loc",routingMode:.full,bypassRegion:nil)
   a.activeTunnel=p; h=VEXHelperModel(a); a.nativePSKHelper=h
   h.status = .init(isUsableConnectedStatus:connected,hasManagedNetworkState:false,endpoint:"old")
   if connected {try! a.nativeAdmittedProfiles.record(tunnel:p,canonicalConfig:"old-profile",ownerTokenSHA256:h.client.digest("fixture-owner"),scope:try! a.nativeAdmittedProfileScopeForFixture(p),helper:h)}
   return (a,h,p)
  }
  func check(_ name:String,_ ok:Bool) { cases += 1; if !ok { failures += 1 }; print("psk_protected \(name)=\(ok ? "PASS" : "FAIL")") }
  do {
   let (a,h,p)=base(); h.hasConfirmedIdleStatus=true
   _=try await a.run(p,h)
   check("confirmed-idle-cache-only",a.activeTunnel?.id=="next" && a.connects==0 && h.client.replacements==0 && a.profileService.promotions==1)
  } catch { check("confirmed-idle-cache-only",false) }
  for name in ["unconfirmed-idle","managed-idle","nil-access","revoked-access","unvalidated-helper","foreign-helper","external-active"] {
   let (a,h,p)=base(!name.contains("idle"))
   switch name {
   case "managed-idle": h.hasConfirmedIdleStatus=true; h.status.hasManagedNetworkState=true
   case "nil-access": a.entitlement=nil
   case "revoked-access": a.entitlement?.hasPaidAccess=false
   case "unvalidated-helper": h.canUseExistingValidatedHelper=false
   case "foreign-helper": a.nativePSKHelper=nil
   case "external-active": a.activeTunnel=nil
   default: break
   }
   do { _=try await a.run(p,h); check(name,false) }
   catch { check(name,a.connects==0 && h.client.replacements==0 && a.profileService.promotions==0) }
  }
  do {
   let (a,h,p)=base(true); _=try await a.run(p,h)
   check("owned-fresh-commit",a.activeTunnel?.id=="next" && a.nativePSKPreparedTunnel?.id=="next" && a.connects==0 && h.client.replacements==1 && h.client.commits==1 && h.client.recoveries==0 && a.profileService.promotions==1 && a.profileService.writes==1 && !a.isVpnBusy && !h.isBusy)
  } catch { check("owned-fresh-commit",false) }
  do {
   let (a,h,p)=base(true); a.mode = .connectThrows
   do { _=try await a.run(p,h); check("protected-rollback-no-reconnect",false) }
   catch { check("protected-rollback-no-reconnect",a.activeTunnel==p && a.connects==0 && h.client.replacements==1 && h.client.recoveries==1 && a.profileService.writes==2 && a.profileService.promotions==0 && !h.hasPendingProtectedReplacement) }
  }
  for mode in [Mode.sessionChanges,.tokenChanges,.accountChanges,.vpnGenerationChanges,.accessRevoked,.selectionChanges,.routingChanges,.helperChanges] {
   let (a,h,p)=base(true); a.mode=mode
   do { _=try await a.run(p,h); check("stale-\(mode)",false) }
   catch { check("stale-\(mode)",a.activeTunnel==p && a.connects==0 && h.client.replacements==1 && h.client.commits==0 && h.client.recoveries==0 && a.profileService.promotions==0 && a.nativePushEventError==nil && h.hasPendingProtectedReplacement && !a.isVpnBusy && !h.isBusy) }
  }
  do {
   let (a,h,p)=base(true); a.mode = .promotionThrows
   do { _=try await a.run(p,h); check("cache-failure-retains-confirmed-candidate",false) }
   catch { check("cache-failure-retains-confirmed-candidate",a.activeTunnel?.id=="next" && a.nativePSKPreparedTunnel?.id=="next" && a.connects==0 && h.client.commits==1 && h.client.recoveries==0 && a.profileService.promotions==1 && a.nativePushEventError != nil) }
  }
  do {
   let (a,h,p)=base(true); a.mode = .promotionThrows
   _=try? await a.run(p,h); let generation=a.vpnOperationGeneration; a.mode = .success
   let result=try await a.retry(h)
   check("cache-only-retry",result==generation && a.vpnOperationGeneration==generation && a.nativePSKCommittedPromotion==nil && a.nativePushEventError==nil && a.activeTunnel?.id=="next" && a.connects==0 && h.client.replacements==1 && h.client.commits==1 && h.client.recoveries==0 && h.client.snapshots==2 && a.profileService.promotions==2 && a.profileService.writes==1 && !a.isVpnBusy && !h.isBusy)
  } catch { check("cache-only-retry",false) }
  do {
   let (a,h,p)=base(true); a.mode = .promotionThrows; _=try? await a.run(p,h)
   do { _=try await a.retry(h); check("cache-retry-io-failure-retained",false) }
   catch { check("cache-retry-io-failure-retained",a.nativePSKCommittedPromotion != nil && a.activeTunnel?.id=="next" && a.connects==0 && h.client.replacements==1 && h.client.commits==1 && h.client.recoveries==0 && a.profileService.promotions==2 && a.profileService.writes==1 && !a.isVpnBusy && !h.isBusy) }
  }
  for mode in [Mode.snapshotThrows,.snapshotOwnerChanges,.snapshotCandidateChanges,.snapshotJournal,.snapshotScopeChanges] {
   let (a,h,p)=base(true); a.mode = .promotionThrows; _=try? await a.run(p,h); a.mode=mode
   do { _=try await a.retry(h); check("cache-retry-\(mode)",false) }
   catch { check("cache-retry-\(mode)",a.nativePSKCommittedPromotion != nil && a.connects==0 && h.client.replacements==1 && h.client.commits==1 && h.client.recoveries==0 && a.profileService.promotions==1 && a.profileService.writes==1 && !a.isVpnBusy && !h.isBusy) }
  }
  for mode in [Mode.sessionChanges,.tokenChanges,.accountChanges,.vpnGenerationChanges,.accessRevoked,.selectionChanges,.routingChanges,.helperChanges] {
   let (a,h,p)=base(true); a.mode = .promotionThrows; _=try? await a.run(p,h); a.mode=mode; try? a.boundary()
   do { _=try await a.retry(h); check("cache-retry-stale-\(mode)",false) }
   catch { check("cache-retry-stale-\(mode)",a.nativePSKCommittedPromotion != nil && a.connects==0 && h.client.replacements==1 && h.client.commits==1 && h.client.snapshots==1 && a.profileService.promotions==1 && a.profileService.writes==1) }
  }
  do {
   let (_,h,_)=base(true)
   do { try await h.revalidateProtectedCommit(.init(transactionID:"unproven",candidateSHA256:"unproven",latestHandshake:100),isCurrent:{true});check("unproven-receipt-rejected",false) }
   catch { check("unproven-receipt-rejected",h.client.snapshots==0 && h.client.replacements==0 && h.client.commits==0) }
  }

  do {
   let (a,h,p)=base(true);a.profileService.sourceDNSChanged=true
   _=try await a.run(p,h)
   let admitted=try a.nativeAdmittedProfiles.source(for:a.activeTunnel!,scope:try a.nativeAdmittedProfileScopeForFixture(a.activeTunnel!),helper:h)
   check("rotating-source-DNS-exact-admitted-bytes",a.activeTunnel?.id=="next" && h.client.commits==1 && a.profileService.sourcePrepares==0 && a.profileService.candidatePrepares==1 && admitted.canonicalConfig=="next-profile" && admitted.ownerTokenSHA256==h.client.digest("fixture-owner"))
  } catch {check("rotating-source-DNS-exact-admitted-bytes",false)}
  for name in ["missing-admission","different-installation","different-helper-instance","changed-owner-intent"] {
   let (a,h,p)=base(true)
   switch name {
   case "missing-admission":a.nativeAdmittedProfiles.clear()
   case "different-installation":a.nativePushIdentityStore.value="other"
   case "different-helper-instance":let foreign=VEXHelperModel(a);try! a.nativeAdmittedProfiles.record(tunnel:p,canonicalConfig:"old-profile",ownerTokenSHA256:h.client.digest("fixture-owner"),scope:try! a.nativeAdmittedProfileScopeForFixture(p),helper:foreign)
   default:a.foreignOwner=true
   }
   do {_=try await a.run(p,h);check(name,false)}catch {check(name,a.activeTunnel==p && h.client.replacements==0 && h.client.commits==0 && h.client.recoveries==0 && a.profileService.writes==0 && a.connects==0)}
  }
  do {
   let (a,h,p)=base(true);a.mode = .promotionThrows;_=try? await a.run(p,h)
   let admitted=try a.nativeAdmittedProfiles.source(for:a.activeTunnel!,scope:try a.nativeAdmittedProfileScopeForFixture(a.activeTunnel!),helper:h)
   a.nativeAdmittedProfiles.clear();a.mode = .success
   do {_=try await a.retry(h);check("cache-failure-retains-binding-and-invalidation-fences-retry",false)}catch {
    check("cache-failure-retains-binding-and-invalidation-fences-retry",admitted.canonicalConfig=="next-profile" && h.client.snapshots==1 && h.client.replacements==1 && a.profileService.promotions==1)
   }
  }catch {check("cache-failure-retains-binding-and-invalidation-fences-retry",false)}


  do {
   let (a,h,p)=base(true);a.mode = .commitReplyLost
   _=try await a.run(p,h)
   let admitted=try a.nativeAdmittedProfiles.source(for:a.activeTunnel!,scope:try a.nativeAdmittedProfileScopeForFixture(a.activeTunnel!),helper:h)
   check("lost-commit-ack-promotes-exact-proven-candidate",a.activeTunnel?.id=="next" && admitted.canonicalConfig=="next-profile" && a.profileService.promotions==1 && a.profileService.writes==1 && h.client.replacements==1 && h.client.commits==1 && h.client.recoveries==0 && a.connects==0)
  }catch {check("lost-commit-ack-promotes-exact-proven-candidate",false)}

  print("psk_protected_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0 : 1)
 }
}
'''.replace("WRAPPER", wrapper).replace("REVALIDATE", revalidate).replace("CUTOVER", cutover).replace("SCOPE_BODY",scope_body)
if not store.exists():
    HARNESS += LEGACY_STORE_FIXTURE
if not coordinator.exists():
    HARNESS += "\n@MainActor final class NativeProtectedReplacementCoordinator { struct Receipt: Equatable { let transactionID:String; let candidateSHA256:String; let latestHandshake:UInt64 }; var hasPendingTransaction=false }\n"

scratch = Path(os.environ.get("TMPDIR", "/tmp")).resolve()
with tempfile.TemporaryDirectory(prefix="psk-protected-", dir=scratch) as raw:
    directory=Path(raw)
    (directory / "main.swift").write_text(HARNESS)
    subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", "-parse-as-library",
                    *([str(coordinator)] if coordinator.exists() else []), *([str(store)] if store.exists() else []), str(directory / "main.swift"),
                    "-o", str(directory / "probe")], check=True, timeout=180)
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe")], timeout=60).returncode)
