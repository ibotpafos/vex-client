#!/usr/bin/env python3
"""Exercise the actual normal-pending preflight body with inert helper ports only."""
from pathlib import Path
import os, subprocess, sys, tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"
src = (S / "Stores/VEXAppState.swift").read_text()

def body(sig):
    a = src.index(sig); b = src.index("{", a); depth = 1; i = b + 1
    while depth:
        depth += (src[i] == "{") - (src[i] == "}"); i += 1
    return src[a:i]

receipt = body("    func receivedNativeRemoteNotification(")
reconcile = body("    private func reconcileNativeNormalProfileChange(")
has_preflight = "    private func processNativeNormalPendingProfile() async" in src
has_expiry = "normalAuthorizationExpiresAt" in (S / "Models/VEXModels.swift").read_text()
preflight = body("    private func processNativeNormalPendingProfile() async") if has_preflight else "    private func processNativeNormalPendingProfile() async {}"
pending = body("    private var nativeNormalPendingTunnel: PreparedTunnel?") if "    private var nativeNormalPendingTunnel: PreparedTunnel?" in src else "private var nativeNormalPendingTunnel: PreparedTunnel?"

swift = r'''
import Foundation
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
@MainActor final class Helper {
 var canUseExistingValidatedHelper=true, isBusy=false, refreshResult=true; var refreshes=0; var status=HelperStatus()
 func refreshStatus(quiet:Bool=true) async -> Bool { refreshes += 1; return refreshResult }
}
@MainActor final class Profile {
 var fetches=0, writes=0, connects=0, handshakes=0, acks=0, failSecond=false; var hook:((Int)->Void)?
 func invalidateNormalCache(accountID:String?) throws {}
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
 var canUseNativeRemotePush=true,nativeRemotePushEnabled=true,nativePushConsentMatchesSession=true
 var isVpnBusy=false,isDeviceBusy=false,isServerSelectionBusy=false,isNativePSKPreparationBusy=false
 var session:Session?=Session(user:User(id:"a"),accessToken:"t"); var authenticatedSessionGeneration=1,nativePushSessionGeneration:Int?=1,vpnOperationGeneration=1,nativeNormalProfileReconciliationGeneration=0
 var nativePushAccountID:String?="a",nativePushDeviceID:String?="d"; var entitlement:Entitlement?=Entitlement(active:true,vpnAccess:true)
 var accountDevices:[VpnDevice]=[device()]; var selectedLocationId="de",targetLocationId:String?="de",routingMode:VpnRoutingMode = .fullTunnel
 var activeTunnel:PreparedTunnel?,nativePSKPreparedTunnel:PreparedTunnel?; var desiredVpnState:DesiredVpnState = .connected; var nativePSKHelper:Helper?
 private var nativeNormalPendingStorage: (tunnel: PreparedTunnel, stagedAt: Date, isCurrent: @MainActor () -> Bool)?
 PENDING
 var nativePushEventOwner:NativePushPSKEventOwner?,nativePushEventError:String?; var profileWarmupTask:Task<Void,Never>?
 let profileService=Profile(); let nativePushRegistration=Reg(),nativePushIdentityStore=Identity(),nativePushPSKQueue=Queue()
 func ensureAuthenticatedSessionCurrent(generation:Int,accessToken:String,accountID:String)throws { guard generation==authenticatedSessionGeneration,session?.accessToken==accessToken,session?.user.id==accountID else { throw AuthenticatedOperationError.sessionChanged } }
 func tunnel(_ tunnel:PreparedTunnel,matches status:HelperStatus)->Bool { status.matches && tunnel == activeTunnel }
 func refreshCustomerState()async {}; func processNativePSKEvents()async {}; func stage(_ t:PreparedTunnel)->Bool { nativeNormalPendingTunnel=t; return nativeNormalPendingTunnel != nil }
 func pending()->PreparedTunnel? { nativeNormalPendingTunnel }; func runPreflight()async { await processNativeNormalPendingProfile() }
 EXPIRE_BODY
 RECEIPT
 RECONCILE
 PREFLIGHT
}
func drain() async { for _ in 0..<128 { await Task.yield() } }
@main struct Main { @MainActor static func main() async {
 func active()->H { let h=H(); h.activeTunnel=tunnel(device()); h.nativePSKHelper=Helper(); return h }
 let ok=active(); let source=ok.activeTunnel!; ok.receivedNativeRemoteNotification(["aps":["content-available":1]]); await drain()
 let success=ok.profileService.fetches==2 && ok.pending()==candidate(device()) && ok.activeTunnel==source && ok.nativePSKPreparedTunnel==nil && ok.nativePSKHelper!.refreshes==1 && ok.profileService.writes==0 && ok.profileService.connects==0 && ok.profileService.handshakes==0 && ok.profileService.acks==0 && ok.nativePushIdentityStore.creates==0 && ok.nativePushPSKQueue.enqueues==0
 func reject(_ mutate:@escaping @MainActor (H)->Void) async -> Bool { let h=active(); precondition(h.stage(candidate(device()))); let source=h.activeTunnel!; mutate(h); await h.runPreflight(); return h.activeTunnel==source && h.profileService.writes==0 && h.profileService.connects==0 && h.profileService.handshakes==0 && h.profileService.acks==0 && h.nativePushIdentityStore.creates==0 && h.nativePushPSKQueue.enqueues==0 }
 let readiness=await reject { $0.nativePSKHelper!.canUseExistingValidatedHelper=false }
 let retainedStatus=await reject { $0.nativePSKHelper!.refreshResult=false }
 let idle=await reject { $0.nativePSKHelper!.status.usable=false }
 let intent=await reject { $0.desiredVpnState = .disconnected }
 let owner=await reject { $0.session=Session(user:User(id:"b"),accessToken:"t") }
 let deviceChanged=await reject { $0.nativePushIdentityStore.value="other" }
 let route=await reject { $0.targetLocationId="fi" }
 let foreign=active(); precondition(foreign.stage(candidate(device()))); foreign.profileService.hook={ n in if n==1 { foreign.nativePSKHelper=Helper() } }; let foreignOld=foreign.activeTunnel!; await foreign.runPreflight(); let foreignReject=foreign.activeTunnel==foreignOld && foreign.profileService.connects==0
 let expiry=active(); precondition(expiry.stage(candidate(device()))); expiry.nativePSKHelper!.refreshResult=true; expiry.profileService.hook={ n in if n==1 { expiry.expirePendingProof() } }; let old=expiry.activeTunnel!; await expiry.runPreflight(); let expired=expiry.activeTunnel==old && expiry.pending()==nil && expiry.profileService.writes==0 && expiry.profileService.connects==0
 let stale=active(); precondition(stale.stage(candidate(device()))); stale.profileService.hook={ n in if n==2 { stale.authenticatedSessionGeneration+=1 } }; let staleOld=stale.activeTunnel!; await stale.runPreflight(); let staleGuard=stale.activeTunnel==staleOld && stale.pending()==candidate(device()) && stale.profileService.connects==0
 let all=success && readiness && retainedStatus && idle && intent && owner && deviceChanged && route && foreignReject && expired && staleGuard
 print("normal_pending_preflight driver_present=DRIVER_PRESENT success=\(success) fetches=\(ok.profileService.fetches) strict_no_mutation=\(ok.profileService.writes==0 && ok.profileService.connects==0 && ok.profileService.handshakes==0 && ok.profileService.acks==0) rejects=\(readiness && retainedStatus && idle && intent && owner && deviceChanged && route && foreignReject) expiry_clear=\(expired) stale_preserves=\(staleGuard)")
 exit(DRIVER_PRESENT ? (all ? 0 : 1) : 1)
} }
'''.replace("PENDING",pending).replace("RECEIPT",receipt).replace("RECONCILE",reconcile).replace("PREFLIGHT",preflight).replace("VEXHelperModel","Helper").replace("DRIVER_PRESENT","true" if has_preflight else "false").replace("EXPIRY_ARG",",normalAuthorizationExpiresAt:fixtureExpiry" if has_expiry else "").replace("EXPIRE_BODY","func expirePendingProof() { guard var stored=nativeNormalPendingStorage else { return }; stored.tunnel.normalAuthorizationExpiresAt=Date().addingTimeInterval(-1); nativeNormalPendingStorage=stored }" if has_expiry else "func expirePendingProof() {}")

tmp=Path(os.environ.get("TMPDIR","/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-25-tests/tmp")); tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix="normal-preflight-",dir=tmp) as raw:
 d=Path(raw); (d/"main.swift").write_text(swift)
 subprocess.run(["rtk","proxy","swiftc","-swift-version","5","-parse-as-library",str(S/"Models/VEXModels.swift"),str(d/"main.swift"),"-o",str(d/"probe")],check=True)
 raise SystemExit(subprocess.run(["rtk","proxy",str(d/"probe")]).returncode)
