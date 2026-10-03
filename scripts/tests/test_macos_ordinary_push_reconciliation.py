#!/usr/bin/env python3
"""Actual receipt/reconciliation bodies, real device/tunnel models, inert ports."""
from pathlib import Path
import os, subprocess, sys, tempfile
ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / 'macos-native/Sources/VEXNativeMac'
src = (S / 'Stores/VEXAppState.swift').read_text()
def body(sig):
    a=src.index(sig); b=src.index('{',a); n=1; i=b+1
    while n:
        n+=(src[i]=='{')-(src[i]=='}'); i+=1
    return src[a:i]
receipt=body('    func receivedNativeRemoteNotification(')
reconcile=body('    private func reconcileNativeNormalProfileChange(') if '    private func reconcileNativeNormalProfileChange(' in src else ''
pending=body('    private var nativeNormalPendingTunnel: PreparedTunnel?') if '    private var nativeNormalPendingTunnel: PreparedTunnel?' in src else ''
swift=r'''
import Foundation
let fixtureExpiry=Date(timeIntervalSinceReferenceDate:3_200_000_000)
struct User {let id:String}; struct Session {let user:User;let accessToken:String}
enum Registration {case registered, other}
enum AuthenticatedOperationError:Error {case sessionChanged}
struct NativePushPSKEvent {let deviceID:String;static func parse(_ info:[String:Any])->NativePushPSKEvent? {guard let v=info["vex"] as? [String:String],let id=v["device_id"] else {return nil};return Self(deviceID:id)}}
struct NativePushPSKEventOwner {init?(accountID:String,installationID:String){}}
@MainActor final class Identity {var value:String?="install";var creates=0;func existingDeviceId()->String? {value};func getOrCreateDeviceId()->String {creates+=1;return value ?? "created"}}
@MainActor final class Queue {func enqueue(_ e:NativePushPSKEvent,owner:NativePushPSKEventOwner)throws->Bool {true}}
@MainActor final class Reg {var status:Registration = .registered}
@MainActor final class Trace {var actions:[String]=[]}
@MainActor final class Profile {
 let trace:Trace;var fetches=0,completions=0;var hook:(()->Void)?
 init(_ t:Trace){trace=t}
 func invalidateNormalCache(accountID:String?)throws {trace.actions.append("invalidate:"+(accountID ?? "nil"))}
 func refreshRegisteredNormalProfile(accessToken:String,device:VpnDevice,locationId:String,routingMode:VpnRoutingMode,accountID:String,validateCurrent:@MainActor () throws->Void)async throws->PreparedTunnel {
  try validateCurrent();fetches+=1;trace.actions.append("readonly-fetch");await Task.yield();hook?();try validateCurrent();completions+=1;return tunnel(device)
 }
}
@MainActor func device()->VpnDevice {try! JSONDecoder().decode(VpnDevice.self,from:Data(#"{"id":"d","status":"active","platform":"macos","provisioning_mode":"managed_native","client_key_ownership":"client","protocol":"amneziawg","external_device_id":"install"}"#.utf8))}
func tunnel(_ d:VpnDevice)->PreparedTunnel {PreparedTunnel(device:d,config:"inert signed-service port",locationId:"de",profileVersion:7,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture",rotationRequired:false,normalAuthorizationExpiresAt:fixtureExpiry)}
@MainActor final class H {
 // No protected-source restore in these legacy fixtures; durable replay fences have their own actual-store matrix.
 var hasNativeProtectedSourceRestorationFence=false
 var canUseNativeRemotePush=true,nativeRemotePushEnabled=true,nativePushConsentMatchesSession=true
 var isVpnBusy=false,isDeviceBusy=false,isServerSelectionBusy=false,isNativePSKPreparationBusy=false
 var session:Session?=Session(user:User(id:"a"),accessToken:"t")
 var authenticatedSessionGeneration=1,nativePushSessionGeneration:Int?=1,vpnOperationGeneration=1
 var nativeNormalProfileReconciliationGeneration=0
 var nativePushAccountID:String?="a",nativePushDeviceID:String?="d"
 var entitlement:Entitlement?=Entitlement(active:true,vpnAccess:true)
 var accountDevices:[VpnDevice]=[device()]
 var selectedLocationId="de",targetLocationId:String?="de",routingMode:VpnRoutingMode = .fullTunnel
 var activeTunnel:PreparedTunnel?,nativePSKPreparedTunnel:PreparedTunnel?
 private var nativeNormalPendingStorage: (tunnel: PreparedTunnel, stagedAt: Date, isCurrent: @MainActor () -> Bool)?
 PENDING
 var nativePushEventOwner:NativePushPSKEventOwner?,nativePushEventError:String?
 var profileWarmupTask:Task<Void,Never>?
 let trace=Trace();let profileService:Profile
 let nativePushRegistration=Reg(),nativePushIdentityStore=Identity(),nativePushPSKQueue=Queue()
 init(){profileService=Profile(trace)}
 func ensureAuthenticatedSessionCurrent(generation:Int,accessToken:String,accountID:String)throws {
  guard generation==authenticatedSessionGeneration,session?.accessToken==accessToken,session?.user.id==accountID else {throw AuthenticatedOperationError.sessionChanged}
 }
 func refreshCustomerState()async {trace.actions.append("refresh")}
 func processNativePSKEvents()async {trace.actions.append("psk")}
 func processNativeNormalPendingProfile()async {trace.actions.append("normal-pending")}
 func hasNormalPendingTunnel()->Bool { nativeNormalPendingTunnel != nil }
 RECEIPT
 RECONCILE
}
func drain()async {for _ in 0..<128 {await Task.yield()}}
@main struct Main {
 @MainActor static func main()async {
  let aps:[String:Any]=["aps":["content-available":1]]
  let h=H();h.receivedNativeRemoteNotification(aps)
  let synchronous=h.trace.actions==["invalidate:a"];await drain()
  let current=synchronous && h.profileService.fetches==1 && h.nativePSKPreparedTunnel==tunnel(device()) && h.activeTunnel==nil && h.nativePushIdentityStore.creates==0
  print("ordinary_registered_reconciliation=\(current) synchronous_owner_invalidation=\(synchronous) readonly_fetches=\(h.profileService.fetches)")
  guard current else {exit(1)}
  let active=H();active.activeTunnel=tunnel(device());let original=active.activeTunnel
  active.receivedNativeRemoteNotification(aps);await drain()
  // The legacy fixture returns version 7, identical to the owned active
  // profile: it remains unstageable while preserving every original result.
  precondition(active.activeTunnel==original && active.nativePSKPreparedTunnel==nil && !active.hasNormalPendingTunnel() && active.profileService.fetches==1)
  let bad=H();bad.receivedNativeRemoteNotification(["aps":["content-available":1],"vex":["bad":true]]);await drain()
  precondition(bad.trace.actions.isEmpty && bad.profileService.fetches==0 && bad.nativePushIdentityStore.creates==0)
  let psk=H();psk.receivedNativeRemoteNotification(["aps":["content-available":1],"vex":["device_id":"d"]]);await drain()
  precondition(psk.profileService.fetches==0 && !psk.trace.actions.contains("invalidate:a"))
  let late=H();late.receivedNativeRemoteNotification(aps);late.session=Session(user:User(id:"b"),accessToken:"new");await drain()
  precondition(late.trace.actions==["invalidate:a"] && late.profileService.fetches==0 && late.nativePSKPreparedTunnel==nil)
  let newer=H();newer.profileService.hook={newer.profileService.hook=nil;newer.receivedNativeRemoteNotification(aps)}
  newer.receivedNativeRemoteNotification(aps);await drain()
  precondition(newer.profileService.fetches==2 && newer.profileService.completions==1 && newer.nativeNormalProfileReconciliationGeneration==2 && newer.nativePSKPreparedTunnel==tunnel(device()))
  var rejected=0
  let changes:[(String,@MainActor (H)->Void)]=[
   ("session",{$0.authenticatedSessionGeneration+=1}), ("token",{$0.session=Session(user:User(id:"a"),accessToken:"new")}),
   ("registration",{$0.nativePushRegistration.status = .other}), ("device",{$0.nativePushDeviceID="other"}),
   ("install",{$0.nativePushIdentityStore.value="other"}), ("target",{$0.targetLocationId="fi"}),
   ("selection",{$0.selectedLocationId="fi"}), ("routing",{$0.routingMode = .allExceptRu}),
   ("vpn-intent",{$0.vpnOperationGeneration+=1}), ("entitlement",{$0.entitlement=Entitlement(active:false,vpnAccess:false)}),
   ("busy",{$0.isVpnBusy=true}), ("account-device",{$0.accountDevices[0].status="revoked"}),
   ("prepared",{$0.nativePSKPreparedTunnel=tunnel(device())})]
  for (name,change) in changes {
   let x=H();x.profileService.hook={change(x)};x.receivedNativeRemoteNotification(aps);await drain()
   precondition(x.profileService.fetches==1 && x.activeTunnel==nil && x.nativePushEventError==nil)
   if name != "prepared" {precondition(x.nativePSKPreparedTunnel==nil)}
   rejected+=1
  }
  for change in [changes[2].1,changes[3].1,changes[4].1,changes[9].1,changes[10].1,changes[11].1] {
   let x=H();change(x);x.receivedNativeRemoteNotification(aps);await drain();precondition(x.profileService.fetches==0)
  }
  print("ordinary scope matrix PASS late_changes=\(rejected); newer push supersedes old suspended fetch; active unchanged, malformed/PSK no normal fetch, stale session only prior captured-owner eviction; no helper/API/Keychain/VPN use")
 }
}
'''.replace('RECEIPT',receipt).replace('RECONCILE',reconcile).replace('PENDING',pending)
tmp=Path(os.environ.get('TMPDIR','/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-22-native/tmp'));tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='ordinary-push-',dir=tmp) as raw:
    d=Path(raw);(d/'main.swift').write_text(swift)
    subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',str(S/'Models/VEXModels.swift'),str(d/'main.swift'),'-o',str(d/'probe')],check=True)
    raise SystemExit(subprocess.run(['rtk','proxy',str(d/'probe')]).returncode)
