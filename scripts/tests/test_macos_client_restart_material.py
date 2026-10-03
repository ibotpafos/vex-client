#!/usr/bin/env python3
"""Exact service and explicit app body with actual pinned signing/private custody.
Only owned disposable files, in-memory existing keys and inert root RPC ports.
"""
from pathlib import Path
import os,subprocess,sys,tempfile,re
ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac';P=S/'Services'
MATERIAL=['signed-exact-material-without-DNS-or-key-creation','missing-existing-key','changed-existing-key','inconsistent-existing-key','source-install','source-key','source-status','candidate-version','candidate-routing','candidate-bypass','candidate-private-key','canonical-psk','canonical-dns','canonical-routes','canonical-mtu','canonical-endpoint-port','canonical-AWG','canonical-duplicate-endpoint','canonical-source-hash','canonical-candidate-hash','signed-envelope-expired','signed-envelope-wrong-owner','signed-envelope-wrong-device','signed-envelope-wrong-location','signed-envelope-wrong-routing','signed-envelope-tampered-PSK','signed-envelope-invalid-signature']
APP=['explicit-recovery-two-proofs-cache-no-reconnect','cache-failure-shows-proven-candidate-and-retains-intent','exact-cache-failure-explicit-retry','root-second-proof-denied-no-promotion','root-adoption-lost-ACK-retry','root-journal-ACK-never-promotes','current-account','current-install','current-device','current-device-key','current-device-status','selected-location','target-location','routing-intent','paid-access','session-generation-after-adoption','token-after-adoption','device-after-adoption','selection-after-adoption','routing-after-adoption','user-vpn-generation-after-proof','user-disconnect-intent-after-proof','current-signed-stage-missing','current-signed-stage-expired','current-key-missing','retained-canonical-tampered','helper-not-validated','helper-instance-changed','authorize-existing-owner-explicit','cancel-existing-owner-explicit','missing-prior-consent-no-adoption','cache-retry-after-capability-expiry-no-re-adoption','rebound-first-proof-denied-no-cache','rebound-signature-expired-no-cache','recovery-drains-exact-events-only','queue-failure-retains-proof-only-retry','cancel-expired-consent-after-scope-change','cancel-foreign-process-denied','completed-recovery-purges-exact-stage']
if not (P/'NativeProtectedRestartCoordinator.swift').exists():
 for prefix,names in [('client_restart_material',MATERIAL),('client_restart_app',APP)]:
  for name in names:print(prefix+' '+name+'=FAIL (client restart implementation absent)')
  print(f'{prefix}_matrix cases={len(names)} failures={len(names)} live_network_commands=0')
 raise SystemExit(1)
def body(text,signature):
 start=text.index(signature);b=text.index('{',start)
 if 'sanitizedMacOSHelperConfig' in signature:b=text.index('{',text.index('\n    ) -> String {',start))
 d=1;e=b+1
 while d:d+=(text[e]=='{')-(text[e]=='}');e+=1
 return text[start:e]
service=(P/'VPNProfileService.swift').read_text();app=(S/'Stores/VEXAppState.swift').read_text();helper=(S/'VEXHelperClient.swift').read_text();support=(ROOT/'macos-native/Sources/VEXHelperCore/SystemSupport.swift').read_text()
methods=['func existingStagedPSKClientPublicKey(', 'func prepareStagedPSKProfile(', 'func verifyProtectedRestartMaterial(', 'func promoteStagedPSKProfile(', 'nonisolated private static func buildRawManagedProfileConfig(', 'nonisolated static func amneziaConfig(', 'nonisolated private static func managedProfileEndpoint(', 'nonisolated static func sanitizedMacOSHelperConfig(', 'nonisolated private static func configHasIPv6InterfaceAddress(', 'nonisolated private static func sanitizedIPv4AllowedIPsLine(', 'nonisolated private static func clean(', 'nonisolated private static func addNumber(', 'nonisolated private static func addString(']
SERVICE='\n'.join(body(service,x) for x in methods)
DEVICE=body(service,'private extension VpnDevice {')
APPBODY=body(app,'    private func applyNativeProtectedRestart(').replace('private func applyNativeProtectedRestart','func applyNativeProtectedRestart')
WRAPPERS='\n'.join(body(helper,x) for x in ['    func authorizeProtectedRestart(', '    func adoptProtectedRestart(', '    func cancelProtectedRestart(', '    func transferProtectedJournal(', '    func resumeProtectedJournal(', '    func restoreProtectedJournal(', '    private func restartDependencies(', '    func revalidateProtectedCommit(', '    func finishProtectedPromotion('] if x in helper)
HARNESS=r"""
import Foundation
import CryptoKit
import Darwin
final class WireGuardKeyStore {var pair:WireGuardKeyPair?;var reads=0;func existingForStagedProfile()->WireGuardKeyPair? {reads+=1;return pair}}
enum VPNProfileError:Error {case incompleteProfile(String)}
enum AuthenticatedOperationError:Error {case sessionChanged}
enum ProbeError:Error {case injected}
enum HelperError:Error {case protocolViolation(String)}
typealias AwgConfigAdmission=ActualAwgConfigAdmission
enum VEXHelperCore {typealias AwgConfigAdmission=ActualAwgConfigAdmission}
enum SystemTunnelController {
 SANITIZER
}
@MainActor final class Cache {var saves=0,fail=false;func save(_ r:PreparedTunnelCacheRecord,locationId:String,routingMode:VpnRoutingMode,owner:VPNProfileCacheOwner)throws {saves+=1;if fail{throw ProbeError.injected}}}
@MainActor final class VPNProfileService {
 let keyStore=WireGuardKeyStore(),cache=Cache();static let awgVersion=3;static var dnsCalls=0
 nonisolated static func resolveConfigEndpoint(_ endpoint:String)->String {fatalError("DNS port must never be called")}
 SERVICE
 func raw(_ profile:ManagedVpnProfile,_ pair:WireGuardKeyPair)throws->String {try Self.buildRawManagedProfileConfig(profile,keyPair:pair,mtu:1420,persistentKeepalive:27,resolveEndpoint:false)}
}
DEVICE
struct User {var id:String}
struct Session {var user:User;var accessToken:String}
struct EntitlementFixture {var hasPaidAccess:Bool}
enum Desired:Equatable {case connected,disconnected}
final class Identity {var value:String?="fixture-install";func existingDeviceId()->String? {value}}
@MainActor final class Client {
 unowned let app:AppState;var calls:[String]=[],mode="",adoptions=0,proofs=0
 let newOwner=String(repeating:"b",count:64)
 init(_ app:AppState){self.app=app}
 func send(_ command:String,timeoutSeconds:Int)async throws->String {
  calls.append(command);let verb=String(command.split(separator:" ").first!)
  let m=app.material!,t=m.intent
  switch verb {
  case "protected-authorize-restart":return "restart-authorized transaction_id=\(t.transactionID) expires_at=\(UInt64(Date().timeIntervalSince1970)+120)\n"
  case "protected-cancel-restart":return "restart-cancelled transaction_id=\(t.transactionID)\n"
  case "protected-adopt-restart":
   adoptions+=1
   if mode=="lost" && adoptions==1{throw ProbeError.injected}
   if mode.hasSuffix("-after-adoption"){app.boundary(mode)}
   return "owner-transferred restart_protocol=1 transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(newOwner) evidence_kind=\(mode=="journal" ? "journal":"receipt")\n"
  case "protected-receipt":
   proofs+=1
    if mode=="proof-denied"{throw ProbeError.injected}
   if mode=="second-proof-denied" && proofs==2 {throw ProbeError.injected}
   if mode.hasSuffix("-after-proof"){app.boundary(mode)}
   return "committed commit_receipt_protocol=1 transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(newOwner) latest_handshake=\(app.handshake)\n"
  default:throw ProbeError.injected
  }
 }
}
@MainActor final class VEXHelperModel {
 let client:Client,protectedReplacement=NativeProtectedReplacementCoordinator(),protectedRestart=NativeProtectedRestartCoordinator()
 var canUseExistingValidatedHelper=true,isBusy=false,hasExplicitRestartConsent=false
 init(_ app:AppState){client=Client(app)}
 func refreshStatus(quiet:Bool) async -> Bool {true}
 WRAPPERS
}
@MainActor final class AppState {
 ACTION_ENUM
 var canUseNativeRemotePush=true,nativeRemotePushEnabled=true,nativePushConsentMatchesSession=true,isVpnBusy=false,isDeviceBusy=false
 var entitlement:EntitlementFixture? = .init(hasPaidAccess:true),session:Session? = .init(user:.init(id:"fixture-account"),accessToken:"fixture-token")
 var nativePushDeviceID:String?="11111111-1111-4111-8111-111111111111",accountDevices:[VpnDevice]=[]
 var selectedLocationId="de",targetLocationId:String?="de",routingMode=VpnRoutingMode.fullTunnel,vpnOperationGeneration=0,authenticatedSessionGeneration=4
 var activeTunnel:PreparedTunnel?,nativePSKPreparedTunnel:PreparedTunnel?,desiredVpnState=Desired.disconnected
 var nativePSKCommittedPromotion:Int?,activeResilienceRoute:Int?,nativeProtectedRestartMessage:String?
 var nativeNormalPendingTunnel:PreparedTunnel?,nativePSKRetryTask:Task<Void,Never>?,profileWarmupTask:Task<Void,Never>?,nativePushRuntimeAllowed=true
 FENCE_PROPERTY
 let nativePushIdentityStore=Identity(),profileService=VPNProfileService(),nativeAdmittedProfiles=NativeAdmittedProfileStore()
 let nativeProtectedRestartStore:NativeProtectedRestartStore,nativeProtectedPromotionStore:NativeProtectedPromotionStore,nativePSKStageStore:NativePSKStagedProfileStore,nativePSKVerifier:NativeVPNProfileAuthorizationVerifier,nativePushPSKQueue:NativePushPSKEventQueue
 weak var nativePSKHelper:VEXHelperModel?
 var material:NativeProtectedRestartStore.Material!,handshake=UInt64(Date().timeIntervalSince1970)-10
 let owner=NativePushPSKEventOwner(accountID:"fixture-account",installationID:"fixture-install")!
 init(root:URL,verifier:NativeVPNProfileAuthorizationVerifier){nativeProtectedRestartStore = .init(appDataURL:root);nativeProtectedPromotionStore = .init(appDataURL:root);nativePSKStageStore = .init(appDataURL:root);nativePSKVerifier=verifier;nativePushPSKQueue = .init(appDataURL:root)}
 func ensureAuthenticatedSessionCurrent(generation:Int,accessToken:String,accountID:String)throws {
  guard generation==authenticatedSessionGeneration,session?.accessToken==accessToken,session?.user.id==accountID else{throw AuthenticatedOperationError.sessionChanged}
 }
 func nativeAdmittedProfileScope(for tunnel:PreparedTunnel)throws->NativeAdmittedProfileStore.Scope {.init(accountID:session!.user.id,installationID:nativePushIdentityStore.existingDeviceId()!,sessionGeneration:authenticatedSessionGeneration)}
 func nativePSKPromotionPersistence(previous:PreparedTunnel,next:PreparedTunnel,owner:NativePushPSKEventOwner,helper:VEXHelperModel,generation:Int,sessionGeneration:Int,token:String)throws->NativeProtectedReplacementCoordinator.Persistence {
  try nativeProtectedPromotionStore.persistence(accountID:owner.accountID,installationID:owner.installationID,scopeFingerprint:NativeProtectedReplacementCoordinator.digest("fixture-fresh-scope"),generation:generation)
 }
 func boundary(_ mode:String){
  if mode=="session-generation-after-adoption"{authenticatedSessionGeneration+=1}
  if mode=="token-after-adoption"{session!.accessToken="different"}
  if mode=="device-after-adoption"{accountDevices=[]}
  if mode=="selection-after-adoption"{selectedLocationId="us"}
  if mode=="routing-after-adoption"{routingMode = .allExceptRu}
  if mode=="user-vpn-generation-after-proof"{vpnOperationGeneration+=1}
  if mode=="user-disconnect-intent-after-proof"{desiredVpnState = .connected}
 }
 APPBODY
}
@MainActor final class Fixture {
 let app:AppState,helper:VEXHelperModel,root:URL,pair:WireGuardKeyPair,signer=P256.Signing.PrivateKey()
 var envelope:PSKRotationCurrentResponse,source:PreparedTunnel,verified:NativeVPNProfileAuthorizationVerifier.Verified
 init(_ label:String,oldProcess:Bool=true)throws {
  root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(label,isDirectory:true)
  let key=Curve25519.KeyAgreement.PrivateKey();pair = .init(privateKey:key.rawRepresentation.base64EncodedString(),publicKey:key.publicKey.rawRepresentation.base64EncodedString(),keyEpoch:1)
  let expiry=ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600)),issued=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-60)),keyData=Data(repeating:2,count:32).base64EncodedString(),psk=Data(repeating:3,count:32).base64EncodedString()
  var p:[String:Any]=["version":2,"device_id":"11111111-1111-4111-8111-111111111111","client_public_key":pair.publicKey,"protocol":"amneziawg","server":"vpn.example","port":51820,"server_public_key":keyData,"preshared_key":psk,"assigned_ipv4":"10.0.0.2/32","dns":["1.1.1.1"],"allowed_ips":["0.0.0.0/0"],"routing_policy_version":"fixture-policy","expires_at":expiry]
  let policy:[String:Any]=["schema":"vex.native-vpn-profile.v1","user_id":"fixture-account","device_id":"11111111-1111-4111-8111-111111111111","assigned_location_id":"de","routing_mode":"full_tunnel","routing_policy_version":"fixture-policy","profile_version":2,"issued_at":issued,"expires_at":expiry,"tunnel":["protocol":"amneziawg","endpoint":"vpn.example:51820","assigned_ipv4":"10.0.0.2/32","server_public_key":keyData,"preshared_key":psk,"dns":["1.1.1.1"],"allowed_ips":["0.0.0.0/0"],"mtu":1420,"persistent_keepalive":27]]
  let payload=try JSONSerialization.data(withJSONObject:policy,options:[.sortedKeys]),signature=try signer.signature(for:payload)
  func b64(_ d:Data)->String {d.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
  p["authorization"]=["algorithm":"ECDSA_P256_SHA256_DER","key_id":"fixture-key","payload_base64":b64(payload),"signature_base64":b64(signature.derRepresentation)]
  let profile=try JSONDecoder().decode(ManagedVpnProfile.self,from:JSONSerialization.data(withJSONObject:p))
  let env:[String:Any]=["rotation_id":"22222222-2222-4222-8222-222222222222","activate":false,"current_version":1,"profile_version":2,"profile_digest":NativePSKRotationValidation.serverStableDigest(profile)!,"deadline_at":expiry,"profile":p]
  envelope=try JSONDecoder().decode(PSKRotationCurrentResponse.self,from:JSONSerialization.data(withJSONObject:env))
  let verifier=NativeVPNProfileAuthorizationVerifier(pinnedPublicKeyDER:["fixture-key":signer.publicKey.derRepresentation]);verified=try verifier.verifyDetailed(envelope,ownerAccountID:"fixture-account",managedDeviceID:"11111111-1111-4111-8111-111111111111",locationID:"de",routingMode:"full_tunnel")
  app=AppState(root:root,verifier:verifier);app.profileService.keyStore.pair=pair
  let dev:[String:Any]=["id":"11111111-1111-4111-8111-111111111111","name":"fixture","status":"active","external_device_id":"fixture-install","public_key":pair.publicKey,"protocol":"amneziawg"]
  let device=try JSONDecoder().decode(VpnDevice.self,from:JSONSerialization.data(withJSONObject:dev))
  let raw=try app.profileService.raw(profile,pair)
  source = .init(device:device,config:raw,locationId:"de",profileVersion:1,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture-policy",rotationRequired:false)
  let next=try app.profileService.prepareStagedPSKProfile(verified,basedOn:source)
  let canonical=try SystemTunnelController.sanitizedConfig(from:VPNProfileService.sanitizedMacOSHelperConfig(next.config,endpointResolver:{_ in "203.0.113.7:51820"}))
  let sourceConfig=canonical.replacingOccurrences(of:psk,with:Data(repeating:4,count:32).base64EncodedString())
  let intent=NativeProtectedReplacementCoordinator.RestartIntent(transactionID:"E63DCEBD-109A-4C45-A23C-3F32BF42597A",sourceSHA256:NativeProtectedReplacementCoordinator.digest(sourceConfig),candidateSHA256:NativeProtectedReplacementCoordinator.digest(canonical),ownerTokenSHA256:String(repeating:"a",count:64),scopeFingerprint:NativeProtectedReplacementCoordinator.digest("old-scope"),processInstanceID:oldProcess ? UUID().uuidString:NativeProtectedReplacementCoordinator.processInstanceID,generation:11)
  try app.nativeProtectedRestartStore.retain(owner:app.owner,intent:intent,rotationID:envelope.rotationID,source:source,candidate:next,sourceConfig:sourceConfig,candidateConfig:canonical,selectedLocationID:"de",targetLocationID:"de")
  app.material=try app.nativeProtectedRestartStore.loadMaterial(owner:app.owner)!
  var data=try JSONSerialization.data(withJSONObject:["schema":1,"scopeFingerprint":intent.scopeFingerprint,"processInstanceID":intent.processInstanceID,"generation":11,"transaction":["id":intent.transactionID,"source":intent.sourceSHA256,"candidate":intent.candidateSHA256,"owner":intent.ownerTokenSHA256,"supportsCommitReceipt":true,"commitResponseUncertain":true],"receipt":["transactionID":intent.transactionID,"candidateSHA256":intent.candidateSHA256,"ownerTokenSHA256":intent.ownerTokenSHA256,"latestHandshake":app.handshake]],options:[.sortedKeys]);data.append(10)
  try NativePushSecureFileStore(rootURL:root,maxBytes:16_384).write(data,name:"promotion-"+NativeProtectedPromotionStore.fingerprint(["vex-protected-promotion-v1",app.owner.accountID,app.owner.installationID])+".json")
  try app.nativePSKStageStore.stage(envelope,owner:app.owner,managedDeviceID:device.id)
  app.accountDevices=[device];helper=VEXHelperModel(app);app.nativePSKHelper=helper
  if oldProcess {_=try app.nativeProtectedRestartStore.capability(owner:app.owner,material:app.material,now:UInt64(Date().timeIntervalSince1970),generate:{String(repeating:"c",count:64)})}
 }
 func alteredMaterial(_ field:String)throws->NativeProtectedRestartStore.Material {
  var o=try JSONSerialization.jsonObject(with:JSONEncoder().encode(app.material!)) as! [String:Any]
  var src=o["source"] as! [String:Any],cand=o["candidate"] as! [String:Any]
  if field=="source-install"{var d=src["device"] as! [String:Any];d["external_device_id"]="other";src["device"]=d}
  if field=="source-key"{var d=src["device"] as! [String:Any];d["public_key"]="other";src["device"]=d}
  if field=="source-status"{var d=src["device"] as! [String:Any];d["status"]="revoked";src["device"]=d}
  if field=="candidate-version"{cand["profileVersion"]=3}
  if field=="candidate-routing"{cand["routingMode"]="all_except_ru"}
  if field=="candidate-bypass"{cand["bypassRegion"]="ru"}
  if field=="candidate-private-key"{cand["config"]="changed"}
  var canonical=o["candidateConfig"] as! String
  if field=="canonical-psk"{canonical=canonical.replacingOccurrences(of:"PresharedKey = ",with:"PresharedKey = bad")}
  if field=="canonical-dns"{canonical=canonical.replacingOccurrences(of:"1.1.1.1",with:"8.8.8.8")}
  if field=="canonical-routes"{canonical=canonical.replacingOccurrences(of:"0.0.0.0/0",with:"10.0.0.0/8")}
  if field=="canonical-mtu"{canonical=canonical.replacingOccurrences(of:"1420",with:"1419")}
  if field=="canonical-endpoint-port"{canonical=canonical.replacingOccurrences(of:"203.0.113.7:51820",with:"203.0.113.7:51821")}
  if field=="canonical-AWG"{canonical += "Jc = 4\n"}
  if field=="canonical-duplicate-endpoint"{canonical += "Endpoint = 203.0.113.8:51820\n"}
  if field=="canonical-source-hash"{o["sourceConfig"]="different"}
  if field=="canonical-candidate-hash"{canonical += "# changed\n"}
  o["source"]=src;o["candidate"]=cand;o["candidateConfig"]=canonical
  return try JSONDecoder().decode(NativeProtectedRestartStore.Material.self,from:JSONSerialization.data(withJSONObject:o))
 }
}
@main struct Main {
 @MainActor static func main()async {
  var mCases=0,mFailures=0,aCases=0,aFailures=0
  func m(_ n:String,_ ok:Bool){mCases+=1;if !ok{mFailures+=1};print("client_restart_material \(n)=\(ok ? "PASS":"FAIL")")}
  func a(_ n:String,_ ok:Bool){aCases+=1;if !ok{aFailures+=1};print("client_restart_app \(n)=\(ok ? "PASS":"FAIL")")}
  do{let f=try Fixture("material-good");let next=try f.app.profileService.verifyProtectedRestartMaterial(f.app.material,verified:f.verified,owner:f.app.owner);m("signed-exact-material-without-DNS-or-key-creation",next==f.app.material.candidate.tunnel && f.helper.client.calls.isEmpty && f.app.profileService.cache.saves==0)}catch{m("signed-exact-material-without-DNS-or-key-creation",false)}
  for name in MATERIAL_NEGATIVES {
   do{
    let f=try Fixture("material-"+name);var denied=false
    if name=="missing-existing-key"{f.app.profileService.keyStore.pair=nil}
    if name=="changed-existing-key"{let key=Curve25519.KeyAgreement.PrivateKey();f.app.profileService.keyStore.pair = .init(privateKey:key.rawRepresentation.base64EncodedString(),publicKey:key.publicKey.rawRepresentation.base64EncodedString(),keyEpoch:2)}
    if name=="inconsistent-existing-key"{f.app.profileService.keyStore.pair = .init(privateKey:f.pair.privateKey,publicKey:"wrong",keyEpoch:1)}
    let material=try f.alteredMaterial(name)
    do{_=try f.app.profileService.verifyProtectedRestartMaterial(material,verified:f.verified,owner:f.app.owner)}catch{denied=true}
    m(name,denied && f.helper.client.calls.isEmpty && f.app.profileService.cache.saves==0)
   }catch{m(name,false)}
  }
  for name in SIGNED_NEGATIVES {
   do{
    let f=try Fixture("signed-"+name);var env=f.envelope,owner="fixture-account",device="11111111-1111-4111-8111-111111111111",loc="de",route="full_tunnel",now=Date()
    if name=="signed-envelope-expired"{now=now.addingTimeInterval(7200)}
    if name=="signed-envelope-wrong-owner"{owner="other"};if name=="signed-envelope-wrong-device"{device="other"};if name=="signed-envelope-wrong-location"{loc="us"};if name=="signed-envelope-wrong-routing"{route="all_except_ru"}
    if name=="signed-envelope-tampered-PSK"{env.profile.presharedKey=Data(repeating:8,count:32).base64EncodedString()}
    if name=="signed-envelope-invalid-signature"{env.profile.authorization!.signatureBase64="AA"}
    var denied=false;do{_=try f.app.nativePSKVerifier.verifyDetailed(env,ownerAccountID:owner,managedDeviceID:device,locationID:loc,routingMode:route,now:now)}catch{denied=true}
    m(name,denied && f.helper.client.calls.isEmpty)
   }catch{m(name,false)}
  }
  do{
   let f=try Fixture("app-good");try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
   a("explicit-recovery-two-proofs-cache-no-reconnect",try f.app.activeTunnel==f.app.material.candidate.tunnel && f.app.profileService.cache.saves==1 && f.helper.client.adoptions==1 && f.helper.client.proofs==2 && f.helper.client.calls.count==3 && !f.app.isVpnBusy && !f.helper.isBusy && (try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner))==nil)
  }catch{a("explicit-recovery-two-proofs-cache-no-reconnect",false)}
  do{
   let f=try Fixture("app-cache");f.app.profileService.cache.fail=true;var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
   a("cache-failure-shows-proven-candidate-and-retains-intent",try failed && f.app.activeTunnel==f.app.material.candidate.tunnel && f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID) && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil)
   f.app.profileService.cache.fail=false;try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
   a("exact-cache-failure-explicit-retry",f.app.profileService.cache.saves==2 && f.helper.client.proofs==4 && f.helper.client.adoptions==1)
  }catch{a("cache-failure-shows-proven-candidate-and-retains-intent",false);a("exact-cache-failure-explicit-retry",false)}
  for mode in ["second-proof-denied","lost","journal"] {
   do{
    let f=try Fixture("app-"+mode);f.helper.client.mode=mode;var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
    if mode=="lost"{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}
    let name=mode=="second-proof-denied" ? "root-second-proof-denied-no-promotion":mode=="lost" ? "root-adoption-lost-ACK-retry":"root-journal-ACK-never-promotes"
    a(name,failed && (mode=="lost" ? f.app.profileService.cache.saves==1 && f.helper.client.adoptions==2:f.app.profileService.cache.saves==0 && f.app.activeTunnel==nil))
   }catch{a("app-"+mode,false)}
  }
  for name in APP_NEGATIVES {
   do{
    let f=try Fixture("scope-"+name)
    if name=="current-account"{f.app.session!.user.id="other"}
    if name=="current-install"{f.app.nativePushIdentityStore.value="other"}
    if name=="current-device"{f.app.nativePushDeviceID="other"}
    if name=="current-device-key"{f.app.accountDevices[0].publicKey="other"}
    if name=="current-device-status"{f.app.accountDevices[0].status="revoked"}
    if name=="selected-location"{f.app.selectedLocationId="us"}
    if name=="target-location"{f.app.targetLocationId="us"}
    if name=="routing-intent"{f.app.routingMode = .allExceptRu}
    if name=="paid-access"{f.app.entitlement = .init(hasPaidAccess:false)}
    if name.hasSuffix("-after-adoption") || name.hasSuffix("-after-proof"){f.helper.client.mode=name}
    if name=="current-signed-stage-missing"{try f.app.nativePSKStageStore.purge(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:f.envelope.rotationID)}
    if name=="current-signed-stage-expired"{var e=f.envelope;e.profile.expiresAt=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-3600));try f.app.nativePSKStageStore.purge(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:e.rotationID);try f.app.nativePSKStageStore.stage(e,owner:f.app.owner,managedDeviceID:f.source.device.id)}
    if name=="current-key-missing"{f.app.profileService.keyStore.pair=nil}
    if name=="retained-canonical-tampered"{let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-material-")}!;try Data("{}\n".utf8).write(to:url);precondition(chmod(url.path,0o600)==0)}
    if name=="helper-not-validated"{f.helper.canUseExistingValidatedHelper=false}
    if name=="helper-instance-changed"{f.app.nativePSKHelper=nil}
    var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
    let after=name.hasSuffix("-after-adoption") || name.hasSuffix("-after-proof")
    a(name,failed && f.app.profileService.cache.saves==0 && f.app.activeTunnel==nil && (after || f.helper.client.calls.isEmpty))
   }catch{a(name,false)}
  }
  do{let f=try Fixture("app-authorize",oldProcess:false);try await f.app.applyNativeProtectedRestart(.authorize,helper:f.helper);a("authorize-existing-owner-explicit",f.helper.hasExplicitRestartConsent && f.helper.client.calls.count==1 && f.app.profileService.cache.saves==0);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper);a("cancel-existing-owner-explicit",!f.helper.hasExplicitRestartConsent && f.helper.client.calls.count==2 && f.app.profileService.cache.saves==0)}catch{a("authorize-existing-owner-explicit",false);a("cancel-existing-owner-explicit",false)}
  do{let f=try Fixture("no-consent");let cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:f.app.material)!;try f.app.nativeProtectedRestartStore.removeCapability(owner:f.app.owner,expected:cap);var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true};a("missing-prior-consent-no-adoption",failed && f.helper.client.calls.isEmpty && f.app.profileService.cache.saves==0)}catch{a("missing-prior-consent-no-adoption",false)}

   func expireCapability(_ f:Fixture)throws {
    let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-capability-")}!
    var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    let issued=UInt64(Date().timeIntervalSince1970)-240;o["issuedAt"]=issued;o["expiresAt"]=issued+120
    var data=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);data.append(10)
    try data.write(to:url);precondition(chmod(url.path,0o600)==0)
   }
   do{
    let f=try Fixture("expired-rebound");f.app.profileService.cache.fail=true
    do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{}
    try expireCapability(f);f.app.profileService.cache.fail=false;try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
    a("cache-retry-after-capability-expiry-no-re-adoption",f.app.profileService.cache.saves==2 && f.helper.client.proofs==4 && f.helper.client.adoptions==1)
   }catch{a("cache-retry-after-capability-expiry-no-re-adoption",false)}
   do{
    let f=try Fixture("rebound-proof-denied");f.app.profileService.cache.fail=true
    do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{}
    f.app.profileService.cache.fail=false;f.helper.client.mode="proof-denied";var failed=false
    do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
    a("rebound-first-proof-denied-no-cache",try failed && f.app.profileService.cache.saves==1 && f.helper.client.proofs==3 && f.helper.client.adoptions==1 && f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID))
   }catch{a("rebound-first-proof-denied-no-cache",false)}
   do{
    let f=try Fixture("rebound-signed-expired");f.app.profileService.cache.fail=true
    do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{}
    f.app.profileService.cache.fail=false;var e=f.envelope;e.profile.expiresAt=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-3600))
    try f.app.nativePSKStageStore.purge(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:e.rotationID);try f.app.nativePSKStageStore.stage(e,owner:f.app.owner,managedDeviceID:f.source.device.id)
    var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
    a("rebound-signature-expired-no-cache",failed && f.app.profileService.cache.saves==1 && f.helper.client.proofs==2 && f.helper.client.adoptions==1)
   }catch{a("rebound-signature-expired-no-cache",false)}
   do{
    let f=try Fixture("events-exact")
    let events=[NativePushPSKEvent(kind:.profile_updated,eventID:"matching-stage",rotationID:f.envelope.rotationID,deviceID:f.source.device.id,profileVersion:2,deadlineAt:nil),.init(kind:.cutover_ready,eventID:"matching-cutover",rotationID:f.envelope.rotationID,deviceID:f.source.device.id,profileVersion:2,deadlineAt:nil),.init(kind:.cutover_ready,eventID:"other-device",rotationID:f.envelope.rotationID,deviceID:"33333333-3333-4333-8333-333333333333",profileVersion:2,deadlineAt:nil),.init(kind:.cutover_ready,eventID:"other-rotation",rotationID:"44444444-4444-4444-8444-444444444444",deviceID:f.source.device.id,profileVersion:2,deadlineAt:nil),.init(kind:.cutover_ready,eventID:"other-version",rotationID:f.envelope.rotationID,deviceID:f.source.device.id,profileVersion:3,deadlineAt:nil)]
    for event in events {try f.app.nativePushPSKQueue.enqueue(event,owner:f.app.owner)}
    let other=NativePushPSKEventOwner(accountID:"other-fixture",installationID:"fixture-install")!;try f.app.nativePushPSKQueue.enqueue(events[0],owner:other)
    try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
    a("recovery-drains-exact-events-only",try f.app.nativePushPSKQueue.events(owner:f.app.owner)==Array(events.dropFirst(2)) && f.app.nativePushPSKQueue.events(owner:other)==[events[0]] && f.app.profileService.cache.saves==1)
   }catch{a("recovery-drains-exact-events-only",false)}
   do{
    let f=try Fixture("events-corrupt");let event=NativePushPSKEvent(kind:.cutover_ready,eventID:"matching-cutover",rotationID:f.envelope.rotationID,deviceID:f.source.device.id,profileVersion:2,deadlineAt:nil)
    try f.app.nativePushPSKQueue.enqueue(event,owner:f.app.owner)
    let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.count==69}!
    let pristine=try Data(contentsOf:url);try Data("{}\n".utf8).write(to:url);precondition(chmod(url.path,0o600)==0)
    var failed=false;do{try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)}catch{failed=true}
    let retained=try f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID) && f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:f.app.material) != nil
    try pristine.write(to:url);precondition(chmod(url.path,0o600)==0);try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
    a("queue-failure-retains-proof-only-retry",try failed && retained && f.app.profileService.cache.saves==2 && f.helper.client.proofs==4 && f.helper.client.adoptions==1 && f.app.nativePushPSKQueue.events(owner:f.app.owner).isEmpty)
   }catch{a("queue-failure-retains-proof-only-retry",false)}
   do{
    let f=try Fixture("expired-cancel",oldProcess:false);try await f.app.applyNativeProtectedRestart(.authorize,helper:f.helper);try expireCapability(f)
    try f.app.nativePSKStageStore.purge(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:f.envelope.rotationID)
    f.app.entitlement = .init(hasPaidAccess:false);f.app.nativeRemotePushEnabled=false;f.app.canUseNativeRemotePush=false;f.app.selectedLocationId="us";f.app.targetLocationId="us";f.app.routingMode = .allExceptRu
    let reads=f.app.profileService.keyStore.reads;try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    a("cancel-expired-consent-after-scope-change",try !f.helper.hasExplicitRestartConsent && f.helper.client.calls.count==2 && f.helper.client.proofs==0 && f.helper.client.adoptions==0 && f.app.profileService.cache.saves==0 && f.app.profileService.keyStore.reads==reads && f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:f.app.material)==nil && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil)
   }catch{a("cancel-expired-consent-after-scope-change",false)}
   do{let f=try Fixture("foreign-cancel");var failed=false;do{try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)}catch{failed=true};a("cancel-foreign-process-denied",failed && f.helper.client.calls.isEmpty && f.app.profileService.cache.saves==0)}catch{a("cancel-foreign-process-denied",false)}
   do{let f=try Fixture("stage-cleanup");try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper);a("completed-recovery-purges-exact-stage",try f.app.nativePSKStageStore.load(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:f.envelope.rotationID)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID) && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil)}catch{a("completed-recovery-purges-exact-stage",false)}

  print("client_restart_material_matrix cases=\(mCases) failures=\(mFailures) live_network_commands=0")
  print("client_restart_app_matrix cases=\(aCases) failures=\(aFailures) live_network_commands=0")
  exit(mFailures+aFailures==0 ? 0:1)
 }
}
"""
HARNESS=HARNESS.replace('ACTION_ENUM',body(app,'    private enum NativeProtectedRestartAction').replace('private enum','enum',1)).replace('MATERIAL_NEGATIVES',repr(MATERIAL[1:20]).replace("'",'"')).replace('SIGNED_NEGATIVES',repr(MATERIAL[20:]).replace("'",'"')).replace('APP_NEGATIVES',repr(APP[6:28]).replace("'",'"')).replace('FENCE_PROPERTY',body(app,'    var hasNativeProtectedSourceRestorationFence:') if '    var hasNativeProtectedSourceRestorationFence:' in app else 'var hasNativeProtectedSourceRestorationFence:Bool {false}').replace('APPBODY',APPBODY).replace('WRAPPERS',WRAPPERS).replace('SERVICE',SERVICE).replace('DEVICE',DEVICE).replace('SANITIZER',body(support,'    public static func sanitizedConfig('))
admission=(ROOT/'macos-native/Sources/VEXHelperCore/AwgConfigAdmission.swift').read_text().replace('public enum AwgConfigAdmission','enum ActualAwgConfigAdmission')
HARNESS=admission+'\n'+HARNESS
if __name__=='__main__':
 with tempfile.TemporaryDirectory(prefix='client-restart-material-',dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
  d=Path(raw);(d/'main.swift').write_text(HARNESS);data=d/'app-data';data.mkdir(mode=0o700)
  files=[S/'Models/VEXModels.swift']+[P/n for n in ['VPNProfileCache.swift','NativeAwgBoolean.swift','NativePSKIdentifier.swift','NativePushPSKEventQueue.swift','NativePushSecureFileStore.swift','NativePSKStagedProfileStore.swift','NativePSKRotationValidation.swift','NativeVPNProfileAuthorizationVerifier.swift','NativeAdmittedProfileStore.swift','NativeProtectedReplacementCoordinator.swift','NativeProtectedPromotionStore.swift','NativeProtectedRestartStore.swift','NativeProtectedRestartCoordinator.swift']]
  r=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,files),str(d/'main.swift'),'-o',str(d/'probe')],capture_output=True);sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
  if r.returncode:raise SystemExit(r.returncode)
  r=subprocess.run(['rtk','proxy',str(d/'probe'),str(data)],capture_output=True,timeout=120);sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
  lines=r.stdout.decode().splitlines();seenM=[x.split(' ')[1].split('=')[0] for x in lines if x.startswith('client_restart_material ')];seenA=[x.split(' ')[1].split('=')[0] for x in lines if x.startswith('client_restart_app ')]
  if seenM!=MATERIAL or seenA!=APP:print('client_restart_material case_order_or_coverage=FAIL');raise SystemExit(1)
  raise SystemExit(r.returncode)
