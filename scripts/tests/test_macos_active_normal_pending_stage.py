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
has_pending='    private var nativeNormalPendingTunnel: PreparedTunnel?' in src
pending=body('    private var nativeNormalPendingTunnel: PreparedTunnel?') if has_pending else 'var nativeNormalPendingTunnel:PreparedTunnel?'
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
 let trace:Trace;var fetches=0,completions=0;var hook:(()->Void)?;var version=8
 init(_ t:Trace){trace=t}
 func invalidateNormalCache(accountID:String?)throws {trace.actions.append("invalidate:"+(accountID ?? "nil"))}
 func refreshRegisteredNormalProfile(accessToken:String,device:VpnDevice,locationId:String,routingMode:VpnRoutingMode,accountID:String,validateCurrent:@MainActor () throws->Void)async throws->PreparedTunnel {
  try validateCurrent();fetches+=1;trace.actions.append("readonly-fetch");await Task.yield();hook?();try validateCurrent();completions+=1;return tunnel(device,version:version)
 }
}
@MainActor func device()->VpnDevice {try! JSONDecoder().decode(VpnDevice.self,from:Data(#"{"id":"d","status":"active","platform":"macos","provisioning_mode":"managed_native","client_key_ownership":"client","protocol":"amneziawg","external_device_id":"install"}"#.utf8))}
func tunnel(_ d:VpnDevice,version:Int=7)->PreparedTunnel {PreparedTunnel(device:d,config:"inert signed-service port",locationId:"de",profileVersion:version,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture",rotationRequired:false,normalAuthorizationExpiresAt:fixtureExpiry)}
@MainActor func signedCandidate(_ version:Int,config:String="inert signed-service port",policy:String="fixture",ranges:Int=0,expiry:Date?=fixtureExpiry)->PreparedTunnel {PreparedTunnel(device:device(),config:config,locationId:"de",profileVersion:version,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:ranges,bypassDomainsCount:0,routingPolicyVersion:policy,rotationRequired:false,normalAuthorizationExpiresAt:expiry)}
@MainActor final class H {
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
 func stage(_ tunnel:PreparedTunnel)->Bool { nativeNormalPendingTunnel=tunnel; return nativeNormalPendingTunnel != nil }
 func pending()->PreparedTunnel? { nativeNormalPendingTunnel }
 func storageEmpty()->Bool { nativeNormalPendingStorage == nil }
 func shiftPendingStagedAt(_ date:Date) { guard var stored=nativeNormalPendingStorage else { return };stored.stagedAt=date;nativeNormalPendingStorage=stored }
 func expirePendingProof() { guard var stored=nativeNormalPendingStorage else { return };stored.tunnel.normalAuthorizationExpiresAt=Date().addingTimeInterval(-1);nativeNormalPendingStorage=stored }
 RECEIPT
 RECONCILE
}
func drain()async {for _ in 0..<128 {await Task.yield()}}
@main struct Main {
 @MainActor static func main()async {
 let aps:[String:Any]=["aps":["content-available":1]]
  if !HAS_PENDING { print("active_normal_pending_matrix baseline_property_absent=true");return }
  func active(_ version:Int=8)->H { let h=H();h.activeTunnel=tunnel(device(),version:7);h.profileService.version=version;return h }
  let h=active();let original=h.activeTunnel!;h.receivedNativeRemoteNotification(aps);await drain()
  let valid=h.pending()==tunnel(device(),version:8) && h.activeTunnel==original && h.nativePSKPreparedTunnel==nil && h.profileService.fetches==1 && h.nativePushIdentityStore.creates==0
  let equal=active();let equalOK = !equal.stage(tunnel(device(),version:7)) && equal.storageEmpty()
  let zero=active();let zeroOK = !zero.stage(tunnel(device(),version:0)) && zero.storageEmpty()
  let missingExpiry=active();let missingExpiryOK = !missingExpiry.stage(signedCandidate(8,expiry:nil)) && missingExpiry.storageEmpty()
  let pastExpiry=active();let pastExpiryOK = !pastExpiry.stage(signedCandidate(8,expiry:Date().addingTimeInterval(-1))) && pastExpiry.storageEmpty()
  let smaller=active();let smallerOK = smaller.stage(tunnel(device(),version:1))
  let configChanged=active();let configChangedOK = configChanged.stage(signedCandidate(7,config:"inert signed-service port node-b"))
  let metadataChanged=active();let metadataChangedOK = metadataChanged.stage(signedCandidate(7,policy:"fixture-b",ranges:1))
  let noSource=H();let noSourceOK = !noSource.stage(tunnel(device(),version:8)) && noSource.storageEmpty()
  let foreignDevice=active();foreignDevice.nativePushDeviceID="other";let foreignDeviceOK = !foreignDevice.stage(tunnel(device(),version:8))
  let foreignInstall=active();foreignInstall.nativePushIdentityStore.value="other";let foreignInstallOK = !foreignInstall.stage(tunnel(device(),version:8))
  let foreignAccount=active();foreignAccount.nativePushAccountID="other";let foreignAccountOK = !foreignAccount.stage(tunnel(device(),version:8))
  let foreignRoute=active();let foreignRouteOK = !foreignRoute.stage(PreparedTunnel(device:device(),config:"inert signed-service port",locationId:"fi",profileVersion:8,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture",rotationRequired:false))
  let changes:[(@MainActor (H)->Void)]=[
   {$0.session=Session(user:User(id:"a"),accessToken:"new")}, {$0.nativePushRegistration.status = .other},
   {$0.nativePushDeviceID="other"}, {$0.nativePushIdentityStore.value="other"}, {$0.selectedLocationId="fi"},
   {$0.routingMode = .allExceptRu}, {$0.vpnOperationGeneration+=1}, {$0.entitlement=Entitlement(active:false,vpnAccess:false)},
   {$0.isVpnBusy=true}, {$0.nativePSKPreparedTunnel=tunnel(device())}, {$0.activeTunnel=nil}]
  var cleared=0
  for change in changes { let x=active();precondition(x.stage(tunnel(device(),version:8)));change(x);if x.pending()==nil && x.storageEmpty(){cleared+=1} }
  let psk=active();precondition(psk.stage(tunnel(device(),version:8)));psk.receivedNativeRemoteNotification(["aps":["content-available":1],"vex":["device_id":"d"]]);await drain();let pskClear=psk.pending()==nil && psk.storageEmpty()
  let obsolete=active();obsolete.profileService.hook={obsolete.receivedNativeRemoteNotification(["aps":["content-available":1],"vex":["device_id":"d"]])};obsolete.receivedNativeRemoteNotification(aps);await drain();let obsoleteClear=obsolete.pending()==nil && obsolete.storageEmpty()
  let expired=active();precondition(expired.stage(tunnel(device(),version:8)));expired.shiftPendingStagedAt(Date().addingTimeInterval(-301));let expiredClear=expired.pending()==nil && expired.storageEmpty()
  let backward=active();precondition(backward.stage(tunnel(device(),version:8)));backward.shiftPendingStagedAt(Date().addingTimeInterval(60));let backwardClear=backward.pending()==nil && backward.storageEmpty()
  let proofExpiry=active();precondition(proofExpiry.stage(tunnel(device(),version:8)));proofExpiry.expirePendingProof();let proofExpiryClear=proofExpiry.pending()==nil && proofExpiry.storageEmpty()
  let ok=valid && equalOK && zeroOK && missingExpiryOK && pastExpiryOK && smallerOK && configChangedOK && metadataChangedOK && noSourceOK && foreignDeviceOK && foreignInstallOK && foreignAccountOK && foreignRouteOK && cleared==changes.count && pskClear && obsoleteClear && expiredClear && backwardClear && proofExpiryClear
  print("active_normal_pending_matrix valid=\(valid) equal_zero_source=\(equalOK && zeroOK && noSourceOK) authorization_expiry_reject=\(missingExpiryOK && pastExpiryOK) smaller_changed=\(smallerOK) same_version_signed_delta=\(configChangedOK && metadataChangedOK) foreign=\(foreignDeviceOK && foreignInstallOK && foreignAccountOK && foreignRouteOK) clears=\(cleared) psk_clear=\(pskClear) obsolete_clear=\(obsoleteClear) expiry=\(expiredClear) backward_clock=\(backwardClear) proof_expiry_clear=\(proofExpiryClear)")
  exit(ok ? 0:1)
 }
}
'''.replace('RECEIPT',receipt).replace('RECONCILE',reconcile).replace('HAS_PENDING','true' if has_pending else 'false').replace('PENDING',pending)
tmp=Path(os.environ.get('TMPDIR','/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-24-active-normal-stage/pending-runtime/tmp'));tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='ordinary-push-',dir=tmp) as raw:
    d=Path(raw);(d/'main.swift').write_text(swift)
    subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',str(S/'Models/VEXModels.swift'),str(d/'main.swift'),'-o',str(d/'probe')],check=True)
    raise SystemExit(0 if '--compile-only' in sys.argv[2:] else subprocess.run(['rtk','proxy',str(d/'probe')]).returncode)
