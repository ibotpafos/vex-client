#!/usr/bin/env python3
"""Actual pending driver + helper wrapper + coordinator; only RPC/config ports are fake."""
from pathlib import Path
import os, subprocess, sys, tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"
src = (S / "Stores/VEXAppState.swift").read_text()

def body(sig, text=src):
    a = text.index(sig); b = text.index("{", a); depth = 1; i = b + 1
    while depth:
        depth += (text[i] == "{") - (text[i] == "}"); i += 1
    return text[a:i]

receipt = body("    func receivedNativeRemoteNotification(")
reconcile = body("    private func reconcileNativeNormalProfileChange(")
has_preflight = "    private func processNativeNormalPendingProfile() async" in src
has_expiry = "normalAuthorizationExpiresAt" in (S / "Models/VEXModels.swift").read_text()
preflight = body("    private func processNativeNormalPendingProfile() async") if has_preflight else "    private func processNativeNormalPendingProfile() async {}"
pending = body("    private var nativeNormalPendingTunnel: PreparedTunnel?") if "    private var nativeNormalPendingTunnel: PreparedTunnel?" in src else "private var nativeNormalPendingTunnel: PreparedTunnel?"
helper_source = (S / "VEXHelperClient.swift").read_text()
protected_wrapper = body("    func replaceProfilePreservingProtection(", helper_source) if "    func replaceProfilePreservingProtection(" in helper_source else ""
coordinator = S / "Services/NativeProtectedReplacementCoordinator.swift"
store = S / "Services/NativeAdmittedProfileStore.swift"
scope_body = body("    private func nativeAdmittedProfileScope(") if "    private func nativeAdmittedProfileScope(" in src else """
    private func nativeAdmittedProfileScope(for tunnel:PreparedTunnel) throws -> NativeAdmittedProfileStore.Scope { .init(accountID:session!.user.id,installationID:nativePushIdentityStore.value!,sessionGeneration:authenticatedSessionGeneration) }
"""
LEGACY_STORE_FIXTURE = '\n@MainActor final class NativeAdmittedProfileStore {\n struct Scope: Equatable { let accountID:String; let installationID:String; let sessionGeneration:Int }\n struct Source { let revision=UUID();let tunnel:PreparedTunnel;let canonicalConfig:String;let ownerTokenSHA256:String;let scope:Scope }\n enum Failure:Error { case staleSource }\n private var value:Source?; private weak var helper:AnyObject?\n @discardableResult func record(tunnel:PreparedTunnel,canonicalConfig:String,ownerTokenSHA256:String,scope:Scope,helper:AnyObject)throws->Source { let v=Source(tunnel:tunnel,canonicalConfig:canonicalConfig,ownerTokenSHA256:ownerTokenSHA256,scope:scope);value=v;self.helper=helper;return v }\n func source(for tunnel:PreparedTunnel,scope:Scope,helper:AnyObject)throws->Source { guard let v=value,v.tunnel==tunnel,v.scope==scope,self.helper === helper else {throw Failure.staleSource};return v }\n func isCurrent(_ source:Source,scope:Scope,helper:AnyObject)->Bool { (try? self.source(for:source.tunnel,scope:scope,helper:helper).revision)==source.revision }\n func clear(){value=nil;helper=nil}\n}\n'

swift = r'''
import Foundation
import Dispatch
import CryptoKit
let fixtureExpiry=Date(timeIntervalSinceReferenceDate:3_200_000_000)
struct User { let id:String }; struct Session { let user:User; let accessToken:String }
enum Registration { case registered, other }; enum DesiredVpnState { case connected, disconnected }
enum AuthenticatedOperationError:Error { case sessionChanged }
struct NativePushPSKEvent { let deviceID:String; static func parse(_ info:[String:Any])->NativePushPSKEvent? { nil } }
struct NativePushPSKEventOwner { init?(accountID:String,installationID:String) {} }
@MainActor final class Identity { var value:String?="install"; var creates=0; func existingDeviceId()->String? { value }; func getOrCreateDeviceId()->String { creates += 1; return value ?? "new" } }
@MainActor final class Queue { var enqueues=0; func enqueue(_ event:NativePushPSKEvent,owner:NativePushPSKEventOwner)throws->Bool { enqueues += 1; return true } }
@MainActor final class Reg { var status:Registration = .registered }
struct HelperStatus { var usable=true; var matches=true; var isUsableConnectedStatus:Bool { usable } }
@MainActor final class FakeClient {
 var replacements=0, recovery=false; var afterReplace:(()->Void)?
 let id="E63DCEBD-109A-4C45-A23C-3F32BF42597A"
 func digest(_ value:String)->String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
 func send(_ command:String, timeoutSeconds:Int) async throws -> String {
  let source=digest("source-endpoint"), candidate=digest("candidate-endpoint"), owner=digest("fixture-owner")
  switch command.split(separator:" ").first {
  case "protected-snapshot": return "protected_protocol=1 recovery_pending=\(recovery) source_sha256=\(source) owner_token_sha256=\(owner) transaction_id=\(id)" + (recovery ? " candidate_sha256=\(candidate)" : "") + "\n"
  case "protected-replace": replacements += 1; recovery=true; afterReplace?(); return "ready transaction_id=\(id) candidate_sha256=\(candidate)\n"
  case "protected-commit": recovery=false; return "committed transaction_id=\(id) candidate_sha256=\(candidate) latest_handshake=100\n"
  case "protected-recover": recovery=false; return "recovered transaction_id=\(id)\n"
  default: throw AuthenticatedOperationError.sessionChanged
  }
 }
}
@MainActor final class Helper {
 var canUseExistingValidatedHelper=true, isBusy=false, refreshResult=true; var refreshes=0; var status=HelperStatus(); var afterRefresh:(()->Void)?
 let client=FakeClient(); private let protectedReplacement=NativeProtectedReplacementCoordinator()
 var hasPendingProtectedReplacement:Bool { protectedReplacement.hasPendingTransaction }
 func refreshStatus(quiet:Bool=true) async -> Bool { refreshes += 1; await Task.yield(); afterRefresh?(); return refreshResult }
 PROTECTED_WRAPPER
}
@MainActor final class Profile {
 var sourcePrepares=0,candidatePrepares=0,sourceDNSChanged=false
 var fetches=0, writes=0, connects=0, handshakes=0, acks=0, failSecond=false; var hook:((Int)->Void)?
 func invalidateNormalCache(accountID:String?) throws {}
 func prepareProtectedHelperConfig(for tunnel:PreparedTunnel,validateCurrent:@MainActor () throws -> Void) async throws -> String {
  try validateCurrent(); await Task.yield(); try validateCurrent();if tunnel.config=="source-endpoint" {sourcePrepares+=1;return sourceDNSChanged ? "DNS-rotated" : tunnel.config};candidatePrepares+=1;return tunnel.config
 }
 func stageProtectedHelperConfig(_ config:String,validateCurrent:@MainActor () throws -> Void) throws { try validateCurrent(); writes += 1 }
 func refreshRegisteredNormalProfile(accessToken:String,device:VpnDevice,locationId:String,routingMode:VpnRoutingMode,accountID:String,validateCurrent:@MainActor () throws -> Void) async throws -> PreparedTunnel {
  try validateCurrent(); fetches += 1; hook?(fetches); await Task.yield(); try validateCurrent()
  if failSecond && fetches >= 2 { throw AuthenticatedOperationError.sessionChanged }
  return candidate(device)
 }
}
@MainActor func device()->VpnDevice { try! JSONDecoder().decode(VpnDevice.self,from:Data(#"{"id":"d","status":"active","platform":"macos","provisioning_mode":"managed_native","client_key_ownership":"client","protocol":"amneziawg","external_device_id":"install"}"#.utf8)) }
func tunnel(_ d:VpnDevice,version:Int=7)->PreparedTunnel { PreparedTunnel(device:d,config:"source-endpoint",locationId:"de",profileVersion:version,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"source-policy",rotationRequired:falseEXPIRY_ARG) }
func candidate(_ d:VpnDevice)->PreparedTunnel { PreparedTunnel(device:d,config:"candidate-endpoint",locationId:"de",profileVersion:8,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"candidate-policy",rotationRequired:falseEXPIRY_ARG) }
@MainActor final class H {
 // No protected-source restore in these legacy fixtures; durable replay fences have their own actual-store matrix.
 var hasNativeProtectedSourceRestorationFence=false
 var canUseNativeRemotePush=true,nativeRemotePushEnabled=true,nativePushConsentMatchesSession=true
 var isVpnBusy=false,isDeviceBusy=false,isServerSelectionBusy=false,isNativePSKPreparationBusy=false
 var session:Session?=Session(user:User(id:"a"),accessToken:"t"); var authenticatedSessionGeneration=1,nativePushSessionGeneration:Int?=1,vpnOperationGeneration=1,nativeNormalProfileReconciliationGeneration=0
 var nativePushAccountID:String?="a",nativePushDeviceID:String?="d"; var entitlement:Entitlement?=Entitlement(active:true,vpnAccess:true)
 var accountDevices:[VpnDevice]=[device()]; var selectedLocationId="de",targetLocationId:String?="de",routingMode:VpnRoutingMode = .fullTunnel
 var activeTunnel:PreparedTunnel?,nativePSKPreparedTunnel:PreparedTunnel?; var desiredVpnState:DesiredVpnState = .connected; var nativePSKHelper:Helper?
 var activeResilienceRoute:String?
 private var nativeNormalPendingStorage: (tunnel: PreparedTunnel, stagedAt: Date, isCurrent: @MainActor () -> Bool)?
 PENDING
 var nativePushEventOwner:NativePushPSKEventOwner?,nativePushEventError:String?; var profileWarmupTask:Task<Void,Never>?
 let nativeAdmittedProfiles=NativeAdmittedProfileStore()
 SCOPE_BODY
 let profileService=Profile(); let nativePushRegistration=Reg(),nativePushIdentityStore=Identity(),nativePushPSKQueue=Queue()
 func ensureAuthenticatedSessionCurrent(generation:Int,accessToken:String,accountID:String)throws { guard generation==authenticatedSessionGeneration,session?.accessToken==accessToken,session?.user.id==accountID else { throw AuthenticatedOperationError.sessionChanged } }
 func tunnel(_ tunnel:PreparedTunnel,matches status:HelperStatus)->Bool { status.matches && tunnel == activeTunnel }
 var receiptFinished=false
 func refreshCustomerState()async {}; func processNativePSKEvents()async { receiptFinished=true }; func stage(_ t:PreparedTunnel)->Bool { nativeNormalPendingTunnel=t; return nativeNormalPendingTunnel != nil }
 func pending()->PreparedTunnel? { nativeNormalPendingTunnel }; func runPreflight()async { await processNativeNormalPendingProfile() }
 EXPIRE_BODY
 RECEIPT
 RECONCILE
 PREFLIGHT
}
// Task.yield() is not a completion barrier. Observe the final inert callback of
// the actual receipt body, with a bounded monotonic deadline for regressions.
@MainActor func awaitReceipt(_ h:H) async -> Bool {
 let deadline=DispatchTime.now().uptimeNanoseconds+5_000_000_000
 while !h.receiptFinished {
  guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
  try? await Task.sleep(nanoseconds:1_000_000)
 }
 return true
}
@main struct Main { @MainActor static func main() async {
 func active()->H { let h=H(); h.activeTunnel=tunnel(device()); h.nativePSKHelper=Helper();try! h.nativeAdmittedProfiles.record(tunnel:h.activeTunnel!,canonicalConfig:"source-endpoint",ownerTokenSHA256:h.nativePSKHelper!.client.digest("fixture-owner"),scope:.init(accountID:"a",installationID:"install",sessionGeneration:1),helper:h.nativePSKHelper!);return h }
 let ok=active(); let source=ok.activeTunnel!; ok.receivedNativeRemoteNotification(["aps":["content-available":1]]); let okFinished=await awaitReceipt(ok)
 let success=okFinished && ok.profileService.fetches==2 && ok.pending()==nil && ok.activeTunnel==candidate(device()) && ok.activeTunnel != source && ok.nativePSKPreparedTunnel==candidate(device()) && ok.nativePSKHelper!.refreshes==2 && ok.nativePSKHelper!.client.replacements==1 && ok.profileService.writes==1 && ok.profileService.connects==0 && ok.profileService.acks==0 && ok.nativePushIdentityStore.creates==0 && ok.nativePushPSKQueue.enqueues==0
 func reject(_ mutate:@escaping @MainActor (H)->Void) async -> Bool { let h=active(); precondition(h.stage(candidate(device()))); let source=h.activeTunnel!; mutate(h); await h.runPreflight(); return h.activeTunnel==source && h.profileService.fetches==0 && h.profileService.writes==0 && h.profileService.connects==0 && h.profileService.handshakes==0 && h.profileService.acks==0 && h.nativePushIdentityStore.creates==0 && h.nativePushPSKQueue.enqueues==0 }
 let readiness=await reject { $0.nativePSKHelper!.canUseExistingValidatedHelper=false }
 let retainedStatus=await reject { $0.nativePSKHelper!.refreshResult=false }
 let idle=await reject { $0.nativePSKHelper!.status.usable=false }
 let intent=await reject { $0.desiredVpnState = .disconnected }
 let owner=await reject { $0.session=Session(user:User(id:"b"),accessToken:"t") }
 let deviceChanged=await reject { $0.nativePushIdentityStore.value="other" }
 let route=await reject { $0.targetLocationId="fi" }
 let foreign=active(); precondition(foreign.stage(candidate(device()))); foreign.nativePSKHelper!.afterRefresh={ foreign.nativePSKHelper=Helper() }; let foreignOld=foreign.activeTunnel!; await foreign.runPreflight(); let foreignReject=foreign.activeTunnel==foreignOld && foreign.profileService.fetches==0 && foreign.profileService.connects==0
 let expiry=active(); precondition(expiry.stage(candidate(device()))); expiry.nativePSKHelper!.refreshResult=true; expiry.profileService.hook={ n in if n==1 { expiry.expirePendingProof() } }; let old=expiry.activeTunnel!; await expiry.runPreflight(); let expired=expiry.activeTunnel==old && expiry.pending()==nil && expiry.profileService.writes==0 && expiry.profileService.connects==0
 let awaitDesired=active(); precondition(awaitDesired.stage(candidate(device()))); awaitDesired.nativePSKHelper!.afterRefresh={ awaitDesired.desiredVpnState = .disconnected }; let awaitDesiredOld=awaitDesired.activeTunnel!; await awaitDesired.runPreflight(); let awaitDesiredReject=awaitDesired.activeTunnel==awaitDesiredOld && awaitDesired.profileService.fetches==0 && awaitDesired.profileService.connects==0
 let stale=active(); precondition(stale.stage(candidate(device()))); stale.profileService.hook={ n in if n==1 { stale.authenticatedSessionGeneration+=1 } }; let staleOld=stale.activeTunnel!; await stale.runPreflight(); let staleGuard=stale.authenticatedSessionGeneration==2 && stale.activeTunnel==staleOld && stale.pending()==nil && stale.profileService.fetches==1 && stale.profileService.connects==0
 let failed=active(); let failedOld=failed.activeTunnel!; failed.profileService.failSecond=true; failed.receivedNativeRemoteNotification(["aps":["content-available":1]]); let failedFinished=await awaitReceipt(failed); let failedOuter=failedFinished && failed.profileService.fetches==2 && failed.activeTunnel==failedOld && failed.pending()==candidate(device()) && failed.nativePushEventError != nil && failed.profileService.connects==0
 let inflight=active(); precondition(inflight.stage(candidate(device()))); let inflightOld=inflight.activeTunnel!; inflight.nativePSKHelper!.client.afterReplace={ inflight.authenticatedSessionGeneration += 1 }; await inflight.runPreflight()
 let inflightSafe=inflight.activeTunnel==inflightOld && inflight.nativePSKPreparedTunnel==nil && inflight.nativePSKHelper!.hasPendingProtectedReplacement && inflight.profileService.connects==0 && inflight.profileService.acks==0
 let dns=active();dns.profileService.sourceDNSChanged=true;precondition(dns.stage(candidate(device())));await dns.runPreflight()
 let dnsSafe=dns.activeTunnel==candidate(device()) && dns.profileService.sourcePrepares==0 && dns.profileService.candidatePrepares==1 && dns.nativePSKHelper!.client.replacements==1
 let missing=active();precondition(missing.stage(candidate(device())));let missingSource=missing.activeTunnel;missing.nativeAdmittedProfiles.clear();await missing.runPreflight()
 let missingSafe=missing.activeTunnel==missingSource && missing.profileService.fetches==0 && missing.profileService.writes==0 && missing.nativePSKHelper!.client.replacements==0
 print("normal_admitted_binding rotating_DNS=\(dnsSafe) missing_source_fenced=\(missingSafe)")
 let entryFence=await reject { $0.hasNativeProtectedSourceRestorationFence=true }
 let lateFence=active();precondition(lateFence.stage(candidate(device())));let lateFenceSource=lateFence.activeTunnel;lateFence.nativePSKHelper!.afterRefresh={lateFence.hasNativeProtectedSourceRestorationFence=true};await lateFence.runPreflight()
 let lateFenceSafe=lateFence.activeTunnel==lateFenceSource && lateFence.profileService.fetches==0 && lateFence.profileService.writes==0 && lateFence.nativePSKHelper!.client.replacements==0
 let fetchedFence=active();precondition(fetchedFence.stage(candidate(device())));let fetchedFenceSource=fetchedFence.activeTunnel;fetchedFence.profileService.hook={n in if n==1 {fetchedFence.hasNativeProtectedSourceRestorationFence=true}};await fetchedFence.runPreflight()
 let fetchedFenceSafe=fetchedFence.activeTunnel==fetchedFenceSource && fetchedFence.profileService.fetches==1 && fetchedFence.profileService.writes==0 && fetchedFence.nativePSKHelper!.client.replacements==0
 print("normal_source_replay_fence entry=\(entryFence) after_status=\(lateFenceSafe) after_profile=\(fetchedFenceSafe) live_network_commands=0")
 let all=entryFence && lateFenceSafe && fetchedFenceSafe && dnsSafe && missingSafe && success && readiness && retainedStatus && idle && intent && owner && deviceChanged && route && foreignReject && awaitDesiredReject && expired && staleGuard && failedOuter && inflightSafe
 print("normal_pending_protected driver_present=DRIVER_PRESENT success=\(success) fetches=\(ok.profileService.fetches) no_generic_connect_or_ack=\(ok.profileService.connects==0 && ok.profileService.acks==0) rejects=\(readiness && retainedStatus && idle && intent && owner && deviceChanged && route && foreignReject && awaitDesiredReject) expiry_clear=\(expired) stale_current=\(staleGuard) outer_failure_retained=\(failedOuter) stale_inflight_retained=\(inflightSafe)")
 exit(DRIVER_PRESENT ? (all ? 0 : 1) : 1)
} }
'''.replace("SCOPE_BODY",scope_body).replace("PENDING",pending).replace("RECEIPT",receipt).replace("RECONCILE",reconcile).replace("PREFLIGHT",preflight).replace("PROTECTED_WRAPPER",protected_wrapper).replace("VEXHelperModel","Helper").replace("DRIVER_PRESENT","true" if has_preflight else "false").replace("EXPIRY_ARG",",normalAuthorizationExpiresAt:fixtureExpiry" if has_expiry else "").replace("EXPIRE_BODY","func expirePendingProof() { guard var stored=nativeNormalPendingStorage else { return }; stored.tunnel.normalAuthorizationExpiresAt=Date().addingTimeInterval(-1); nativeNormalPendingStorage=stored }" if has_expiry else "func expirePendingProof() {}")
if not store.exists():
    swift += LEGACY_STORE_FIXTURE
if not coordinator.exists():
    swift += "\n@MainActor final class NativeProtectedReplacementCoordinator { var hasPendingTransaction=false }\n"

tmp=Path(os.environ.get("TMPDIR","/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-25-tests/tmp")); tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix="normal-preflight-",dir=tmp) as raw:
 d=Path(raw); (d/"main.swift").write_text(swift)
 subprocess.run(["rtk","proxy","swiftc","-swift-version","5","-parse-as-library",str(S/"Models/VEXModels.swift"),*([str(coordinator)] if coordinator.exists() else []),*([str(store)] if store.exists() else []),str(d/"main.swift"),"-o",str(d/"probe")],check=True)
 raise SystemExit(subprocess.run(["rtk","proxy",str(d/"probe")]).returncode)
