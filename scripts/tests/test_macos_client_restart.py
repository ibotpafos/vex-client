#!/usr/bin/env python3
"""Actual client restart custody/coordinator/rebind; owned fixtures/inert RPC only.
No app, installed helper, Keychain, DNS, API, APNs or live network command.
"""
from pathlib import Path
import os,subprocess,sys,tempfile
ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac';P=S/'Services'
CASES=['authorize-custody-before-socket','authorize-ack-loss-retains-exact-capability','authorize-retry-does-not-extend','authorize-current-process-only','authorize-expired-custody-no-RPC','authorize-reject-backwards-clock','cancel-expired-consent-explicitly','cancel-denied-preserves-custody','adopt-then-independent-root-proof','adopt-never-reuses-old-owner-for-proof','adopt-lost-ack-retries-same-capability','adopt-denied-proof-no-binding-write','adopt-journal-is-not-commit','adopt-live-old-process-denied','signed-material-revalidation-before-any-RPC','material-revalidated-after-adoption','scope-change-after-adoption-no-proof','scope-change-after-proof-no-result','transport-error-redacted','root-error-reflection-redacted']
for phase in ['authorize','adopt','proof']:
 for fault in ['unknown','duplicate','wrong-id','noncanonical','newline','oversize']:CASES.append(phase+'-reply-'+fault+'-denied')
CASES += ['strict-durable-old-intent','ordinary-cross-process-load-still-denied','explicit-rebind-preserves-generation-and-material','rebind-retry-exact-idempotent','generic-save-cannot-rebind','rebind-wrong-root-owner-denied','rebind-changed-handshake-denied','second-proof-before-cache-completion','two-proof-fault-retains-private-custody','capability-not-in-promotion-metadata','canonical-material-replay-only','other-account-has-no-material','other-install-has-no-material','material-invalid-hash-denied','material-unknown-field-denied','material-symlink-denied','material-hardlink-denied','capability-open-mode-denied','capability-oversize-denied','capability-unknown-field-denied','capability-material-digest-denied','unsafe-custody-parent-denied','random-capability-256bits','explicit-cleanup-preserves-other-owner','app-explicit-actions-wired','app-retains-before-stage','app-two-proofs-before-promotion','app-fresh-device-and-signed-stage-gates','app-no-normal-connect-or-DNS-recovery','source-metadata-not-admission']
if not (P/'NativeProtectedRestartCoordinator.swift').exists():
 for name in CASES:print('client_restart '+name+'=FAIL (client restart implementation absent)')
 print(f'client_restart_matrix cases={len(CASES)} failures={len(CASES)} live_network_commands=0')
 raise SystemExit(1)
HARNESS=r"""
import Foundation
import CryptoKit
import Darwin
struct NativePushPSKEventOwner:Equatable {let accountID:String;let installationID:String}
enum ProbeError:Error {case injected}
@MainActor final class Disk {
 let owner=NativePushPSKEventOwner(accountID:"fixture-account",installationID:"fixture-install"),root:URL
 let store:NativeProtectedRestartStore,promotion:NativeProtectedPromotionStore
 var material:NativeProtectedRestartStore.Material!,clock:UInt64=UInt64(Date().timeIntervalSince1970),current=true,invalid=false
 var calls:[String]=[],fault="",failFirst=false,changedAfter="",validations=0
 let id="E63DCEBD-109A-4C45-A23C-3F32BF42597A",oldOwner=String(repeating:"a",count:64),newOwner=String(repeating:"b",count:64),cap=String(repeating:"c",count:64)
 var intent:NativeProtectedReplacementCoordinator.RestartIntent!
 init(_ label:String,oldProcess:Bool=false)throws {
  root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(label,isDirectory:true)
  store=NativeProtectedRestartStore(appDataURL:root);promotion=NativeProtectedPromotionStore(appDataURL:root)
  let device=try JSONDecoder().decode(VpnDevice.self,from:Data("{\"id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"fixture\",\"status\":\"active\",\"external_device_id\":\"fixture-install\"}".utf8))
  let source=PreparedTunnel(device:device,config:"source-raw",locationId:"de",profileVersion:1,routingMode:.fullTunnel,bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"fixture-policy",rotationRequired:false)
  var candidate=source;candidate.config="candidate-raw";candidate.profileVersion=2
  intent = .init(transactionID:id,sourceSHA256:NativeProtectedReplacementCoordinator.digest("source-canonical"),candidateSHA256:NativeProtectedReplacementCoordinator.digest("candidate-canonical"),ownerTokenSHA256:oldOwner,scopeFingerprint:NativeProtectedReplacementCoordinator.digest("old-scope"),processInstanceID:oldProcess ? UUID().uuidString:NativeProtectedReplacementCoordinator.processInstanceID,generation:11)
  try store.retain(owner:owner,intent:intent,rotationID:"22222222-2222-4222-8222-222222222222",source:source,candidate:candidate,sourceConfig:"source-canonical",candidateConfig:"candidate-canonical",selectedLocationID:"de",targetLocationID:"de")
  material=try store.loadMaterial(owner:owner)!
 }
 var deps:NativeProtectedRestartCoordinator.Dependencies {
  .init(isCurrent:{self.current},validateMaterial:{self.validations += 1;if self.invalid{throw ProbeError.injected}},send:{try await self.send($0,$1)},store:store,owner:owner,material:material,now:{self.clock},generateCapability:{self.cap})
 }
 func capability()throws->NativeProtectedRestartStore.Capability {try store.capability(owner:owner,material:material,now:clock,generate:{cap})}
 var files:URL {root.appendingPathComponent("push-psk-events")}
 func file(_ kind:String)->URL {try! FileManager.default.contentsOfDirectory(at:files,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix(kind+"-")}!}
 func send(_ command:String,_ timeout:Int)async throws->String {
  calls.append(command);let verb=String(command.split(separator:" ").first!)
  if failFirst {failFirst=false;throw ProbeError.injected}
  if fault=="throw" {throw NSError(domain:cap,code:1,userInfo:[NSLocalizedDescriptionKey:cap])}
  var value:String
  switch verb {
  case "protected-authorize-restart":
   guard try store.loadCapability(owner:owner,material:material)?.value==cap else{throw ProbeError.injected}
   value="restart-authorized transaction_id=\(id) expires_at=\(clock+120)\n"
  case "protected-cancel-restart":value="restart-cancelled transaction_id=\(id)\n"
  case "protected-adopt-restart":
   value="owner-transferred restart_protocol=1 transaction_id=\(id) source_sha256=\(intent.sourceSHA256) candidate_sha256=\(intent.candidateSHA256) owner_token_sha256=\(newOwner) evidence_kind=\(fault=="journal" ? "journal":"receipt")\n"
  case "protected-receipt":value="committed commit_receipt_protocol=1 transaction_id=\(id) source_sha256=\(intent.sourceSHA256) candidate_sha256=\(intent.candidateSHA256) owner_token_sha256=\(newOwner) latest_handshake=\(clock-10)\n"
  default:throw ProbeError.injected
  }
  if changedAfter==verb {current=false}
  if fault=="invalidate-after-adopt" && verb=="protected-adopt-restart" {invalid=true}
  let target=fault.split(separator: ":").map(String.init)
  if target.count==2 && target[0]==verb {
   switch target[1] {
   case "unknown":value=String(value.dropLast())+" restart_capability=\(cap)\n"
   case "duplicate":value=String(value.dropLast())+" transaction_id=\(id)\n"
   case "wrong-id":value=value.replacingOccurrences(of:id,with:UUID().uuidString)
   case "noncanonical":value=value.replacingOccurrences(of:" ",with:"  ")
   case "newline":value=String(value.dropLast())+"\nsecret=\(cap)\n"
   case "oversize":value=String(repeating:"x",count:4097)+"\n"
   default:break
   }
  }
  return value
 }
 func tamper(_ kind:String,_ f:(inout [String:Any])->Void)throws {
  let url=file(kind);var value=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];f(&value)
  var data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);data.append(10)
  try NativePushSecureFileStore(rootURL:root,maxBytes:1_048_576).write(data,name:url.lastPathComponent)
 }
 func oldIntentBytes(receipt:Bool=true)throws->Data {
  var object:[String:Any]=["schema":1,"scopeFingerprint":intent.scopeFingerprint,"processInstanceID":intent.processInstanceID,"generation":intent.generation,"transaction":["id":id,"source":intent.sourceSHA256,"candidate":intent.candidateSHA256,"owner":oldOwner,"supportsCommitReceipt":true,"commitResponseUncertain":true]]
  if receipt {object["receipt"]=["transactionID":id,"candidateSHA256":intent.candidateSHA256,"ownerTokenSHA256":oldOwner,"latestHandshake":clock-10]}
  var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);return data
 }
 func putIntent(_ data:Data)throws {
  let name="promotion-"+NativeProtectedPromotionStore.fingerprint(["vex-protected-promotion-v1",owner.accountID,owner.installationID])+".json"
  try NativePushSecureFileStore(rootURL:root,maxBytes:16_384).write(data,name:name)
 }
}
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0
  func check(_ name:String,_ value:Bool){cases+=1;if !value{failures+=1};print("client_restart \(name)=\(value ? "PASS":"FAIL")")}
  let c=NativeProtectedRestartCoordinator()
  do {
   let s=try Disk("authorize");let expiry=try await c.authorize(s.deps)
   check("authorize-custody-before-socket",expiry==s.clock+120 && s.calls.count==1 && s.calls[0].contains(s.cap) && s.validations>=2)
   let retry=try Disk("lost-auth");retry.failFirst=true;var denied=false
   do{_=try await c.authorize(retry.deps)}catch{denied=true}
   let old=try retry.store.loadCapability(owner:retry.owner,material:retry.material)!
   check("authorize-ack-loss-retains-exact-capability",denied && old.value==retry.cap)
   retry.clock += 1;let second=try await c.authorize(retry.deps)
   check("authorize-retry-does-not-extend",second==old.expiresAt && retry.calls[0]==retry.calls[1])
  }catch{check("authorize-custody-before-socket",false);check("authorize-ack-loss-retains-exact-capability",false);check("authorize-retry-does-not-extend",false)}
  for mode in ["process","expired","backwards"] {
   do {
    let s=try Disk("auth-"+mode,oldProcess:mode=="process");_=try s.capability()
    if mode=="expired" {s.clock+=120};if mode=="backwards" {s.clock-=1}
    var denied=false;do{_=try await c.authorize(s.deps)}catch{denied=true}
    let name=mode=="process" ? "authorize-current-process-only":mode=="expired" ? "authorize-expired-custody-no-RPC":"authorize-reject-backwards-clock"
    check(name,denied && s.calls.isEmpty)
   }catch{check("authorize-"+mode,false)}
  }
  do{let s=try Disk("cancel");_=try s.capability();s.clock+=121;try await c.cancel(s.deps);check("cancel-expired-consent-explicitly",try s.store.loadCapability(owner:s.owner,material:s.material)==nil && s.calls.count==1)}catch{check("cancel-expired-consent-explicitly",false)}
  do{let s=try Disk("cancel-denied");_=try s.capability();s.failFirst=true;var denied=false;do{try await c.cancel(s.deps)}catch{denied=true};check("cancel-denied-preserves-custody",try denied && s.store.loadCapability(owner:s.owner,material:s.material) != nil)}catch{check("cancel-denied-preserves-custody",false)}
  do {
   let s=try Disk("adopt",oldProcess:true);_=try s.capability();let receipt=try await c.adopt(s.deps)
   check("adopt-then-independent-root-proof",receipt.ownerTokenSHA256==s.newOwner && s.calls.count==2 && s.validations>=3)
   check("adopt-never-reuses-old-owner-for-proof",s.calls[0].contains(s.oldOwner) && s.calls[1].contains(s.newOwner) && !s.calls[1].contains(s.cap))
  }catch{check("adopt-then-independent-root-proof",false);check("adopt-never-reuses-old-owner-for-proof",false)}
  for mode in ["lost","proof-denied","journal","same-process","invalid","invalidate-after-adopt","scope-adopt","scope-proof","throw","reflection"] {
   do {
    let s=try Disk("adopt-"+mode,oldProcess:mode != "same-process");let cap=try s.capability();var denied=false,safe=false
    if mode=="lost" {s.failFirst=true};if mode=="proof-denied"{s.fault="protected-receipt:wrong-id"};if mode=="journal"{s.fault="journal"};if mode=="invalid"{s.invalid=true};if mode=="invalidate-after-adopt"{s.fault=mode};if mode=="scope-adopt"{s.changedAfter="protected-adopt-restart"};if mode=="scope-proof"{s.changedAfter="protected-receipt"};if mode=="throw"{s.fault="throw"};if mode=="reflection"{s.fault="protected-adopt-restart:unknown"}
    do{_=try await c.adopt(s.deps)}catch{denied=true;safe = !error.localizedDescription.contains(s.cap)}
    if mode=="lost" {_=try await c.adopt(s.deps)}
    let name:[String:String]=["lost":"adopt-lost-ack-retries-same-capability","proof-denied":"adopt-denied-proof-no-binding-write","journal":"adopt-journal-is-not-commit","same-process":"adopt-live-old-process-denied","invalid":"signed-material-revalidation-before-any-RPC","invalidate-after-adopt":"material-revalidated-after-adoption","scope-adopt":"scope-change-after-adoption-no-proof","scope-proof":"scope-change-after-proof-no-result","throw":"transport-error-redacted","reflection":"root-error-reflection-redacted"]
    var expected=try denied && safe && (s.store.loadCapability(owner:s.owner,material:s.material))==cap
    if ["invalid","same-process"].contains(mode){expected = expected && s.calls.isEmpty}
    if ["journal","invalidate-after-adopt","scope-adopt"].contains(mode){expected = expected && s.calls.count==1}
    if mode=="lost"{expected = expected && s.calls.count==3 && s.calls[0]==s.calls[1]}
    check(name[mode]!,expected)
   }catch{check("adopt-"+mode,false)}
  }
  for phase in ["authorize","adopt","proof"] {
   for fault in ["unknown","duplicate","wrong-id","noncanonical","newline","oversize"] {
    do {
     let s=try Disk(phase+"-"+fault,oldProcess:phase != "authorize");_=try s.capability()
     s.fault=(phase=="authorize" ? "protected-authorize-restart":phase=="adopt" ? "protected-adopt-restart":"protected-receipt")+":"+fault
     var denied=false,safe=false;do{if phase=="authorize"{_=try await c.authorize(s.deps)}else{_=try await c.adopt(s.deps)}}catch{denied=true;safe = !error.localizedDescription.contains(s.cap)}
     check(phase+"-reply-"+fault+"-denied",denied && safe)
    }catch{check(phase+"-reply-"+fault+"-denied",false)}
   }
  }
  do {
   let s=try Disk("rebind",oldProcess:true),bytes=try s.oldIntentBytes();try s.putIntent(bytes);_=try s.capability()
   check("strict-durable-old-intent",try NativeProtectedReplacementCoordinator.restartIntent(bytes)==s.intent)
   let scope=NativeProtectedReplacementCoordinator.digest("fresh-scope"),p=try s.promotion.persistence(accountID:s.owner.accountID,installationID:s.owner.installationID,scopeFingerprint:scope,generation:11)
   var ordinary=false;do{_=try await NativeProtectedReplacementCoordinator().replace(sourceSHA256:s.intent.sourceSHA256,candidateSHA256:s.intent.candidateSHA256,sourceOwnerTokenSHA256:s.oldOwner,dependencies:.init(isCurrent:{true},send:{try await s.send($0,$1)},stageCandidate:{},restoreSource:{},persistence:p))}catch{ordinary=true}
   check("ordinary-cross-process-load-still-denied",ordinary && s.calls.isEmpty)
   let proof=try await c.adopt(s.deps),rebuilt=try s.promotion.rebindAfterAuthorizedRestart(accountID:s.owner.accountID,installationID:s.owner.installationID,original:s.intent,receipt:proof,scopeFingerprint:scope,isCurrent:{true})
   let tuple=try NativeProtectedReplacementCoordinator.restartIntent(rebuilt)
   check("explicit-rebind-preserves-generation-and-material",tuple.generation==11 && tuple.transactionID==s.id && tuple.sourceSHA256==s.intent.sourceSHA256 && tuple.candidateSHA256==s.intent.candidateSHA256 && tuple.processInstanceID==NativeProtectedReplacementCoordinator.processInstanceID && tuple.ownerTokenSHA256==s.newOwner)
   let again=try s.promotion.rebindAfterAuthorizedRestart(accountID:s.owner.accountID,installationID:s.owner.installationID,original:s.intent,receipt:proof,scopeFingerprint:scope,isCurrent:{true})
   check("rebind-retry-exact-idempotent",again==rebuilt)
   var generic=false;do{try NativeProtectedReplacementCoordinator.requireSamePersistentIdentity(bytes,rebuilt)}catch{generic=true};check("generic-save-cannot-rebind",generic)
   var bad=false;let wrong=NativeProtectedReplacementCoordinator.Receipt(transactionID:s.id,candidateSHA256:proof.candidateSHA256,latestHandshake:proof.latestHandshake,ownerTokenSHA256:s.oldOwner)
   do{_=try NativeProtectedReplacementCoordinator.reboundRestartIntent(bytes,original:s.intent,receipt:wrong,scopeFingerprint:scope)}catch{bad=true};check("rebind-wrong-root-owner-denied",bad)
   var handshake=false;let changed=NativeProtectedReplacementCoordinator.Receipt(transactionID:s.id,candidateSHA256:proof.candidateSHA256,latestHandshake:proof.latestHandshake+1,ownerTokenSHA256:s.newOwner)
   do{_=try NativeProtectedReplacementCoordinator.reboundRestartIntent(bytes,original:s.intent,receipt:changed,scopeFingerprint:scope)}catch{handshake=true};check("rebind-changed-handshake-denied",handshake)
   let current=NativeProtectedReplacementCoordinator();try await current.revalidateCommitted(proof,isCurrent:{true},send:{try await s.send($0,$1)},persistence:p)
   check("second-proof-before-cache-completion",try s.calls.count==3 && s.calls.last!.hasPrefix("protected-receipt ") && p.load() != nil)
   var fault=false;do{try await NativeProtectedReplacementCoordinator().revalidateCommitted(proof,isCurrent:{true},send:{_,_ in throw ProbeError.injected},persistence:p)}catch{fault=true}
   check("two-proof-fault-retains-private-custody",try fault && s.store.loadCapability(owner:s.owner,material:s.material) != nil && p.load()==rebuilt)
   check("capability-not-in-promotion-metadata",!String(decoding:rebuilt,as:UTF8.self).contains(s.cap) && !String(decoding:rebuilt,as:UTF8.self).contains("canonical"))
  }catch{for name in ["strict-durable-old-intent","ordinary-cross-process-load-still-denied","explicit-rebind-preserves-generation-and-material","rebind-retry-exact-idempotent","generic-save-cannot-rebind","rebind-wrong-root-owner-denied","rebind-changed-handshake-denied","second-proof-before-cache-completion","two-proof-fault-retains-private-custody","capability-not-in-promotion-metadata"]{check(name,false)}}
  do{
   let s=try Disk("replay");try s.store.retain(owner:s.owner,intent:s.intent,rotationID:s.material.rotationID,source:s.material.source.tunnel,candidate:s.material.candidate.tunnel,sourceConfig:s.material.sourceConfig,candidateConfig:s.material.candidateConfig,selectedLocationID:"de",targetLocationID:"de")
   check("canonical-material-replay-only",try s.store.loadMaterial(owner:s.owner)==s.material)
   check("other-account-has-no-material",try s.store.loadMaterial(owner:.init(accountID:"other",installationID:s.owner.installationID))==nil)
   check("other-install-has-no-material",try s.store.loadMaterial(owner:.init(accountID:s.owner.accountID,installationID:"other"))==nil)
  }catch{for name in ["canonical-material-replay-only","other-account-has-no-material","other-install-has-no-material"]{check(name,false)}}
  for mode in ["hash","unknown","symlink","hardlink"] {
   do{
    let s=try Disk("material-"+mode),url=s.file("restart-material")
    if mode=="hash"{try s.tamper("restart-material"){$0["candidateConfig"]="different"}}
    if mode=="unknown"{try s.tamper("restart-material"){$0["credential"]="fixture-secret"}}
    if mode=="symlink"{let external=s.root.appendingPathComponent("external");try FileManager.default.moveItem(at:url,to:external);precondition(symlink(external.path,url.path)==0)}
    if mode=="hardlink"{precondition(link(url.path,s.root.appendingPathComponent("other-link").path)==0)}
    var denied=false;do{_=try s.store.loadMaterial(owner:s.owner)}catch{denied=true}
    check("material-"+(mode=="hash" ? "invalid-hash":mode=="unknown" ? "unknown-field":mode)+"-denied",denied)
   }catch{check("material-"+mode+"-denied",false)}
  }
  for mode in ["open-mode","oversize","unknown-field","material-digest"] {
   do{
    let s=try Disk("cap-"+mode);_=try s.capability();let url=s.file("restart-capability")
    if mode=="open-mode"{precondition(chmod(url.path,0o644)==0)}
    if mode=="oversize"{try Data(repeating:0,count:16_385).write(to:url);precondition(chmod(url.path,0o600)==0)}
    if mode=="unknown-field"{try s.tamper("restart-capability"){$0["unknown"]="x"}}
    if mode=="material-digest"{try s.tamper("restart-capability"){$0["materialSHA256"]=s.oldOwner}}
    var denied=false;do{_=try s.store.loadCapability(owner:s.owner,material:s.material)}catch{denied=true}
    check("capability-"+mode+"-denied",denied)
   }catch{check("capability-"+mode+"-denied",false)}
  }
  do{let s=try Disk("parent"),saved=s.root.deletingLastPathComponent().appendingPathComponent("saved-parent");try FileManager.default.moveItem(at:s.root,to:saved);precondition(symlink(saved.path,s.root.path)==0);var denied=false;do{_=try s.store.loadMaterial(owner:s.owner)}catch{denied=true};check("unsafe-custody-parent-denied",denied)}catch{check("unsafe-custody-parent-denied",false)}
  do{let a=try NativeProtectedRestartStore.randomCapability(),b=try NativeProtectedRestartStore.randomCapability();check("random-capability-256bits",NativeProtectedReplacementCoordinator.validDigest(a) && NativeProtectedReplacementCoordinator.validDigest(b) && a != b)}catch{check("random-capability-256bits",false)}
  do{let s=try Disk("cleanup");let cap=try s.capability();let other=NativePushPSKEventOwner(accountID:"other",installationID:s.owner.installationID);try s.store.retain(owner:other,intent:s.intent,rotationID:s.material.rotationID,source:s.material.source.tunnel,candidate:s.material.candidate.tunnel,sourceConfig:s.material.sourceConfig,candidateConfig:s.material.candidateConfig,selectedLocationID:"de",targetLocationID:"de");try s.store.removeCapability(owner:s.owner,expected:cap);try s.store.removeMaterial(owner:s.owner,expected:s.material);check("explicit-cleanup-preserves-other-owner",try s.store.loadMaterial(owner:s.owner)==nil && s.store.loadMaterial(owner:other) != nil)}catch{check("explicit-cleanup-preserves-other-owner",false)}
  print("client_restart_runtime_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0:1)
 }
}
"""
def body(text,signature):
 start=text.index(signature);b=text.index('{',start);d=1;e=b+1
 while d:d+=(text[e]=='{')-(text[e]=='}');e+=1
 return text[start:e]
with tempfile.TemporaryDirectory(prefix='client-restart-',dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
 d=Path(raw);(d/'main.swift').write_text(HARNESS);data=d/'app-data';data.mkdir(mode=0o700)
 sources=[S/'Models/VEXModels.swift',P/'VPNProfileCache.swift',P/'NativePSKIdentifier.swift',P/'NativePushSecureFileStore.swift',P/'NativeProtectedReplacementCoordinator.swift',P/'NativeProtectedPromotionStore.swift',P/'NativeProtectedRestartStore.swift',P/'NativeProtectedRestartCoordinator.swift']
 compile=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,sources),str(d/'main.swift'),'-o',str(d/'probe')],capture_output=True)
 sys.stdout.buffer.write(compile.stdout);sys.stderr.buffer.write(compile.stderr)
 if compile.returncode:raise SystemExit(compile.returncode)
 run=subprocess.run(['rtk','proxy',str(d/'probe'),str(data)],capture_output=True,timeout=90)
 sys.stdout.buffer.write(run.stdout);sys.stderr.buffer.write(run.stderr)
 failures=run.returncode
 app=(S/'Stores/VEXAppState.swift').read_text();helper=(S/'VEXHelperClient.swift').read_text();ui=(S/'Views/VEXSettingsView.swift').read_text()
 action=body(app,'    private func applyNativeProtectedRestart(')
 # Receipt recovery assertions remain scoped to the same branch; journal
 # continuation has its independent proof matrix, not receipt-ACK admission.
 receipt_action=action[action.index('        case .recover:'):]
 checks={
 'app-explicit-actions-wired':all(x in ui for x in ['authorizeNativeProtectedRestart','recoverNativeProtectedRestart','cancelNativeProtectedRestart']) and 'authorizeProtectedRestart' in helper,
 'app-retains-before-stage': 'retainNativePSKRestartMaterial(' in body(app,'    private func applyNativePSKCutover(') and action.count('loadMaterial')>0,
 'app-two-proofs-before-promotion':receipt_action.index('adoptProtectedRestart')<receipt_action.index('rebindAfterAuthorizedRestart')<receipt_action.index('revalidateProtectedCommit')<receipt_action.index('promoteStagedPSKProfile')<receipt_action.index('finishProtectedPromotion'),
 'app-fresh-device-and-signed-stage-gates':all(x in action for x in ['accountDevices','nativePSKStageStore.load','nativePSKVerifier.verifyDetailed','existingStagedPSKClientPublicKey','ensureAuthenticatedSessionCurrent']),
 'app-no-normal-connect-or-DNS-recovery':not any(x in action for x in ['connect(using:','disconnect(using:','attachOwnerWatchdog','prepareProtectedHelperConfig','ensureHelperReady','acknowledgePSK']),
 'source-metadata-not-admission':action.index('revalidateProtectedCommit')<action.index('nativeAdmittedProfiles.record')
 }
 for name,value in checks.items():print('client_restart '+name+'='+('PASS' if value else 'FAIL'));failures += not value
 lines=run.stdout.decode().splitlines();seen=[x.split(' ')[1].split('=')[0] for x in lines if x.startswith('client_restart ')] + list(checks)
 if seen != CASES:print('client_restart case_order_or_coverage=FAIL');failures += 1
 runtime_failures=sum('=FAIL' in x for x in lines if x.startswith('client_restart '))
 print(f'client_restart_matrix cases={len(seen)} failures={runtime_failures+sum(not x for x in checks.values())} live_network_commands=0')
 raise SystemExit(0 if not failures else 1)
