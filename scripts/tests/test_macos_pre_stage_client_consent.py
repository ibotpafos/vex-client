#!/usr/bin/env python3
"""Actual App cutover/factory, helper wrapper, coordinator and private stores.
Pinned P-256 signed fixture and existing in-memory key; inert authenticated RPC
and config ports. Root attachment/physical sequencing is separately tested by
test_macos_protected_pre_stage_consent.py. No installed app/helper or network.
"""
from pathlib import Path
import os, runpy, subprocess, sys, tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / 'macos-native/Sources/VEXNativeMac'
P = S / 'Services'
required = {
    P/'NativeProtectedRestartCoordinator.swift': ['func authorizeStage('],
    P/'NativeProtectedRestartStore.swift': ['struct StageConsent'],
    P/'NativeProtectedReplacementCoordinator.swift': ['var stageConsentPending: Bool?'],
    S/'Stores/VEXAppState.swift': ['private func nativePSKStageConsent(', 'private func completeNativePSKPrivatePromotion('],
}
if any(not p.exists() or any(m not in p.read_text() for m in ms) for p, ms in required.items()):
    print('pre_stage_client contract=ABSENT (one diagnostic; missing runtime branches NOT executed)')
    print('pre_stage_client_matrix cases=1 failures=1 live_network_commands=0')
    raise SystemExit(1)

v = runpy.run_path(str(Path(__file__).with_name('test_macos_client_restart_material.py')), run_name='pre_stage_fixture')
body, app, helper = v['body'], v['app'], v['helper']
H = v['HARNESS'].split('@main struct Main {', 1)[0]
start = H.index('@MainActor final class Client {')
end = H.index('@MainActor final class VEXHelperModel {', start)
CLIENT = r'''
@MainActor final class Client {
 unowned let app:AppState
 var calls:[String]=[],mode="",auths=0,replacements=0,commits=0,proofs=0,cancels=0,recoveries=0,snapshots=0
 var custodyBeforeAuth=false,busyAtEveryRPC=true,authorized=false,journal=false,cancelled=false
 var firstAuth="",source="",candidate=""
 init(_ app:AppState){self.app=app}
 func send(_ command:String,timeoutSeconds:Int)async throws->String {
  calls.append(command);busyAtEveryRPC = busyAtEveryRPC && app.nativePSKHelper?.isBusy==true
  let verb=String(command.split(separator:" ").first!),t=app.material.intent
  let owned=try app.nativeProtectedRestartStore.loadMaterial(owner:app.owner)
  switch verb {
  case "protected-snapshot":
   snapshots+=1
   return "protected_protocol=1 recovery_pending=\(journal) source_sha256=\(commits>0 ? t.candidateSHA256:t.sourceSHA256) owner_token_sha256=\(t.ownerTokenSHA256) transaction_id=\(t.transactionID)" + (journal ? " candidate_sha256=\(t.candidateSHA256)":"") + " commit_receipt_protocol=1\n"
  case "protected-authorize-stage":
   auths+=1
   guard let m=owned,let cap=try app.nativeProtectedRestartStore.loadCapability(owner:app.owner,material:m),
         let purpose=try app.nativeProtectedRestartStore.stageConsent(owner:app.owner,material:m),
         let data=try app.nativeProtectedPromotionStore.persistence(accountID:app.owner.accountID,
          installationID:app.owner.installationID,scopeFingerprint:m.intent.scopeFingerprint,generation:m.intent.generation).load() else {throw ProbeError.injected}
   try NativeProtectedReplacementCoordinator.requireUnconsumedStageIntent(data,original:m.intent)
   custodyBeforeAuth = !purpose.cancelled && command.contains("restart_capability="+cap.value) && app.profileService.stageWrites>0
   if firstAuth.isEmpty {firstAuth=command}
   if mode=="unsupported" {return "error: unsupported command\n"}
   if mode=="denied" {return "error: denied "+cap.value+"\n"}
   if mode=="transport-raw" {throw HelperError.protocolViolation(cap.value)}
   authorized=true
   if mode=="lost-authorize" && auths==1 {throw ProbeError.injected}
   if mode=="account-after-auth" {app.session!.user.id="other"}
   if mode=="token-after-auth" {app.session!.accessToken="other"}
   if mode=="install-after-auth" {app.nativePushIdentityStore.value="other"}
   if mode=="device-after-auth" {app.accountDevices=[]}
   if mode=="key-after-auth" {app.profileService.keyStore.pair=nil}
   if mode=="selection-after-auth" {app.selectedLocationId="us"}
   if mode=="generation-after-auth" {app.vpnOperationGeneration+=1}
   if mode=="opt-out-after-auth" {app.nativeProtectedStageConsentEnabled=false}
   if mode=="stage-after-auth" {try app.nativePSKStageStore.purge(owner:app.owner,managedDeviceID:m.source.device.id,rotationID:m.rotationID)}
   let good="stage-authorized transaction_id=\(m.intent.transactionID) expires_at=\(cap.expiresAt)\n"
   if mode=="unknown" {return String(good.dropLast())+" unknown=1\n"}
   if mode=="duplicate" {return String(good.dropLast())+" transaction_id=\(m.intent.transactionID)\n"}
   if mode=="wrong-id" {return good.replacingOccurrences(of:m.intent.transactionID,with:UUID().uuidString)}
   if mode=="expired" {return good.replacingOccurrences(of:String(cap.expiresAt),with:String(cap.issuedAt))}
   if mode=="extended" {return good.replacingOccurrences(of:String(cap.expiresAt),with:String(cap.expiresAt+121))}
   if mode=="CRLF" {return String(good.dropLast())+"\r\n"}
   if mode=="multiline" {return good+good}
   if mode=="empty-token" {return good.replacingOccurrences(of:" ",with:"  ")}
   if mode=="oversize" {return String(repeating:"x",count:4097)+"\n"}
   return good
  case "protected-replace":
   guard authorized || !app.nativeProtectedStageConsentEnabled else {throw ProbeError.injected}
   replacements+=1;journal=true
   return "ready transaction_id=\(t.transactionID) candidate_sha256=\(t.candidateSHA256)\n"
  case "protected-commit":
   commits+=1;journal=false
   if mode=="key-after-commit" {app.profileService.keyStore.pair=nil}
   if mode=="device-after-commit" {app.accountDevices=[]}
   if mode=="stage-after-commit",let m=owned {try app.nativePSKStageStore.purge(owner:app.owner,managedDeviceID:m.source.device.id,rotationID:m.rotationID)}
   return "committed transaction_id=\(t.transactionID) candidate_sha256=\(t.candidateSHA256) latest_handshake=\(app.handshake)\n"
  case "protected-receipt":
   proofs+=1
   guard commits>0,!journal else {throw ProbeError.injected}
   if mode=="proof-denied" {throw ProbeError.injected}
   if mode=="key-after-receipt" {app.profileService.keyStore.pair=nil}
   if mode=="device-after-receipt" {app.accountDevices=[]}
   if mode=="cleanup-file-denied" {
    let url=try FileManager.default.contentsOfDirectory(at:app.fixtureRoot.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-capability-")}!
    precondition(chmod(url.path,0o644)==0)
   }
   return "committed commit_receipt_protocol=1 transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(t.ownerTokenSHA256) latest_handshake=\(app.handshake)\n"
  case "protected-cancel-stage":
   cancels+=1;guard !cancelled,!journal else {throw ProbeError.injected};cancelled=true
   if mode=="lost-cancel" {throw ProbeError.injected}
   if mode=="cancel-private-cleanup-denied" {
    let url=try FileManager.default.contentsOfDirectory(at:app.fixtureRoot.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("promotion-")}!
    precondition(chmod(url.path,0o644)==0)
   }
   return "stage-cancelled transaction_id=\(t.transactionID)\n"
  case "protected-recover":
   recoveries+=1;journal=false;return "recovered transaction_id=\(t.transactionID)\n"
  default:throw ProbeError.injected
  }
 }
}
'''
H = H[:start]+CLIENT+H[end:]
H = H.replace('var canUseExistingValidatedHelper=true,isBusy=false,hasExplicitRestartConsent=false',
    'var status=StageStatus(),hasConfirmedIdleStatus=false\n var hasPendingProtectedReplacement:Bool {protectedReplacement.hasPendingTransaction}\n var canUseExistingValidatedHelper=true,isBusy=false,hasExplicitRestartConsent=false')
H = H.replace('var nativePSKCommittedPromotion:Int?,activeResilienceRoute:Int?,nativeProtectedRestartMessage:String?',
    '''var nativePSKCommittedPromotion:(source:PreparedTunnel,candidate:PreparedTunnel,owner:NativePushPSKEventOwner,receipt:NativeProtectedReplacementCoordinator.Receipt,generation:Int,isCurrent:@MainActor ()->Bool)?
 var activeResilienceRoute:Int?,nativeProtectedRestartMessage:String?,nativePushEventError:String?
 var nativeProtectedStageConsentEnabled=false,errorText=""''')
H = H.replace('init(root:URL,verifier:NativeVPNProfileAuthorizationVerifier){',
    'var fixtureRoot:URL!\n init(root:URL,verifier:NativeVPNProfileAuthorizationVerifier){fixtureRoot=root;')
insert = '\n'.join(body(app, sig).replace('private func', 'func', 1) for sig in [
 '    private func retainNativePSKRestartMaterial(', '    private func nativePSKStageConsent(',
 '    private func completeNativePSKPrivatePromotion(', '    private func applyNativePSKCutover('])
insert += '''
 func ensureConnectStillDesired(generation:Int,sessionGeneration:Int,accessToken:String,accountID:String)throws {
  try ensureAuthenticatedSessionCurrent(generation:sessionGeneration,accessToken:accessToken,accountID:accountID)
  guard desiredVpnState == .connected,vpnOperationGeneration==generation else{throw ProbeError.injected}
 }
 func tunnel(_ t:PreparedTunnel,matches status:StageStatus)->Bool {status.isUsableConnectedStatus}
 func cutover(_ envelope:PSKRotationCurrentResponse,source:PreparedTunnel,helper:VEXHelperModel)async throws->Int {
  try await applyNativePSKCutover(envelope,previous:source,owner:owner,helper:helper,sessionGeneration:4,token:"fixture-token")
 }
'''
H = H.replace(v['APPBODY'], v['APPBODY']+'\n'+insert)
H = H.replace('let keyStore=WireGuardKeyStore(),cache=Cache();static let awgVersion=3;static var dnsCalls=0', '''
 let keyStore=WireGuardKeyStore(),cache=Cache();static let awgVersion=3;static var dnsCalls=0
 var canonicalCandidate="",stageWrites=0,prepares=0
 func prepareProtectedHelperConfig(for tunnel:PreparedTunnel,validateCurrent:@MainActor ()throws->Void)async throws->String {try validateCurrent();prepares+=1;return canonicalCandidate}
 func stageProtectedHelperConfig(_ config:String,validateCurrent:@MainActor ()throws->Void)throws {try validateCurrent();stageWrites+=1}
''')
H = H.replace('@MainActor final class Client {',
    'struct StageStatus {var isUsableConnectedStatus=true,hasManagedNetworkState=true}\n@MainActor final class Client {', 1)
H = H.replace(body(helper,'    func finishProtectedPromotion('),
    body(helper,'    func finishProtectedPromotion(')+'\n'+body(helper,'    func replaceProfilePreservingProtection('))
MAIN = r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0
  func a(_ name:String,_ ok:Bool){cases+=1;if !ok{failures+=1};print("pre_stage_client \(name)=\(ok ? "PASS":"FAIL")")}
  func fresh(_ name:String,optIn:Bool=true)throws->Fixture {
   let f=try Fixture(name,oldProcess:false)
   try f.app.nativeProtectedRestartStore.removeMaterial(owner:f.app.owner,expected:f.app.material)
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.activeTunnel=f.source;f.app.nativePSKPreparedTunnel=f.source;f.app.desiredVpnState = .connected
   f.app.nativeProtectedStageConsentEnabled=optIn;f.app.vpnOperationGeneration=11
   f.app.profileService.canonicalCandidate=f.app.material.candidateConfig
   _=try f.app.nativeAdmittedProfiles.record(tunnel:f.source,canonicalConfig:f.app.material.sourceConfig,
     ownerTokenSHA256:f.app.material.intent.ownerTokenSHA256,scope:try f.app.nativeAdmittedProfileScope(for:f.source),helper:f.helper)
   return f
  }
  func failed(_ f:Fixture)async->Bool {do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper);return false}catch{f.app.errorText=error.localizedDescription+" "+String(describing:error);return true}}
  do {
   let f=try fresh("success");_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   let c=f.helper.client
   a("exact-private-custody-before-authorize-before-replace",c.custodyBeforeAuth && c.auths==1 && c.replacements==1 && c.commits==1 && c.proofs==1 && c.busyAtEveryRPC)
   a("proved-promotion-retires-exact-private-custody-and-nonce",try f.app.profileService.cache.saves==1 && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID) && f.app.nativePSKCommittedPromotion==nil && f.app.activeTunnel?.profileVersion==2)
   a("pre-stage-never-uses-post-journal-authorize-or-adopt",!c.calls.contains{$0.hasPrefix("protected-authorize-restart") || $0.hasPrefix("protected-adopt-restart")} && c.recoveries==0 && VPNProfileService.dnsCalls==0)
  }catch{a("exact-private-custody-before-authorize-before-replace",false);a("proved-promotion-retires-exact-private-custody-and-nonce",false);a("pre-stage-never-uses-post-journal-authorize-or-adopt",false)}
  do {
   let f=try fresh("legacy",optIn:false);_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   a("explicit-no-consent-legacy-contract-remains-compatible",f.helper.client.auths==0 && f.helper.client.replacements==1 && f.app.activeTunnel?.profileVersion==2)
  }catch{a("explicit-no-consent-legacy-contract-remains-compatible",false)}
  for mode in ["unsupported","denied","transport-raw","unknown","duplicate","wrong-id","expired","extended","CRLF","multiline","empty-token","oversize","account-after-auth","token-after-auth","install-after-auth","device-after-auth","key-after-auth","selection-after-auth","generation-after-auth","opt-out-after-auth","stage-after-auth"] {
   do {
    let f=try fresh(mode);f.helper.client.mode=mode;let bad=await failed(f)
    let m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
    let cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)!
    a(mode+"-no-replace-or-legacy-fallback",bad && !f.app.errorText.contains(cap.value) && f.helper.client.auths==1 && f.helper.client.replacements==0 && f.helper.client.commits==0 && f.app.profileService.cache.saves==0 && f.helper.client.recoveries==0)
   }catch{a(mode+"-no-replace-or-legacy-fallback",false)}
  }
  for mode in ["key-after-commit","device-after-commit","stage-after-commit","key-after-receipt","device-after-receipt","proof-denied"] {
   do{let f=try fresh(mode);f.helper.client.mode=mode;let bad=await failed(f)
    a(mode+"-no-cache-or-stale-recovery",bad && f.helper.client.commits==1 && f.app.profileService.cache.saves==0 && f.helper.client.recoveries==0)
   }catch{a(mode+"-no-cache-or-stale-recovery",false)}
  }
  do {
   let f=try fresh("lost-auth");f.helper.client.mode="lost-authorize";let bad=await failed(f)
   let retained=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   let cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:retained)!
   f.helper.client.mode="";_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   let c=f.helper.client,auth=c.calls.filter{$0.hasPrefix("protected-authorize-stage")}
   a("lost-authorize-ACK-exact-nonce-capability-no-TTL-renewal",bad && auth.count==2 && auth[0]==auth[1] && auth[1].contains(cap.value) && c.snapshots==1 && c.replacements==1 && f.app.profileService.prepares==1)
  }catch{a("lost-authorize-ACK-exact-nonce-capability-no-TTL-renewal",false)}
  do {
   let f=try fresh("no-downgrade");f.helper.client.mode="unsupported";_=await failed(f)
   f.app.nativeProtectedStageConsentEnabled=false;f.helper.client.mode="";let bad=await failed(f)
   a("retained-required-consent-cannot-downgrade-after-opt-out",bad && f.helper.client.auths==1 && f.helper.client.replacements==0)
  }catch{a("retained-required-consent-cannot-downgrade-after-opt-out",false)}
  do {
   let f=try fresh("post-stage-renewal");f.helper.client.mode="unsupported";_=await failed(f)
   let m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   var bad=false;do{_=try await f.helper.authorizeProtectedRestart(.init(isCurrent:{true},validateMaterial:{},
    send:{_,_ in fatalError()},store:f.app.nativeProtectedRestartStore,owner:f.app.owner,material:m))}catch{bad=true}
   a("pre-stage-purpose-cannot-renew-through-post-journal-RPC",bad && f.helper.client.calls.count==2 && !f.helper.client.calls.contains{$0.hasPrefix("protected-authorize-restart")})
  }catch{a("pre-stage-purpose-cannot-renew-through-post-journal-RPC",false)}
  do {
   let f=try fresh("cancel");f.helper.client.mode="unsupported";_=await failed(f)
   f.app.selectedLocationId="us";f.app.entitlement = .init(hasPaidAccess:false);f.helper.client.mode=""
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("original-owner-cancel-exact-unconsumed-private-cleanup",try f.helper.client.cancels==1 && f.helper.client.replacements==0 && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID) && f.app.profileService.cache.saves==0)
  }catch{a("original-owner-cancel-exact-unconsumed-private-cleanup",false)}
  do {
   let f=try fresh("lost-cancel");f.helper.client.mode="unsupported";_=await failed(f)
   f.helper.client.mode="lost-cancel";var bad=false;do{try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)}catch{bad=true}
   a("lost-cancel-ACK-retains-inert-custody-not-false-success",try bad && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil && !f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!)!.cancelled && f.helper.client.replacements==0)
  }catch{a("lost-cancel-ACK-retains-inert-custody-not-false-success",false)}
  do {
   let f=try fresh("cache-retry");f.app.profileService.cache.fail=true;let bad=await failed(f)
   let retained=try f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.profileService.cache.fail=false;_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   a("cache-retry-independent-proof-no-new-adoption-or-replace",bad && retained && f.helper.client.auths==1 && f.helper.client.replacements==1 && f.helper.client.commits==1 && f.helper.client.proofs==2 && f.app.profileService.cache.saves==2)
  }catch{a("cache-retry-independent-proof-no-new-adoption-or-replace",false)}
  do {
   let f=try fresh("expired-local-cap");f.helper.client.mode="unsupported";_=await failed(f)
   let dir=f.root.appendingPathComponent("push-psk-events"),url=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-capability-")}!
   var object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
   let issued=UInt64(Date().timeIntervalSince1970)-121;object["issuedAt"]=issued;object["expiresAt"]=issued+120
   var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);try data.write(to:url);precondition(chmod(url.path,0o600)==0)
   f.helper.client.mode="";let bad=await failed(f)
   a("expired-local-consent-no-new-capability-or-RPC",bad && f.helper.client.auths==1 && f.helper.client.replacements==0)
  }catch{a("expired-local-consent-no-new-capability-or-RPC",false)}
  do {
   let f=try fresh("partial-cancel-cleanup");f.helper.client.mode="unsupported";_=await failed(f)
   f.helper.client.mode="cancel-private-cleanup-denied";var bad=false
   do{try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)}catch{bad=true}
   let m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   let marker=try f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:m)!
   let noCap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)==nil
   let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("promotion-")}!
   precondition(chmod(url.path,0o600)==0);f.helper.client.mode=""
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("durable-cancel-ACK-partial-private-cleanup-retry-no-second-RPC",try bad && marker.cancelled && noCap && f.helper.client.cancels==1 && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID))
  }catch{a("durable-cancel-ACK-partial-private-cleanup-retry-no-second-RPC",false)}
  do {
   let f=try fresh("partial-promotion-cleanup");f.helper.client.mode="cleanup-file-denied";let bad=await failed(f)
   let retained=try f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-capability-")}!
   precondition(chmod(url.path,0o600)==0);f.helper.client.mode=""
   _=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   a("private-promotion-cleanup-retry-root-proof-no-new-adoption",try bad && retained && f.helper.client.auths==1 && f.helper.client.replacements==1 && f.helper.client.commits==1 && f.helper.client.proofs==2 && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID))
  }catch{a("private-promotion-cleanup-retry-root-proof-no-new-adoption",false)}
  for kind in ["open-mode","unknown-field","symlink","hardlink"] {
   do {
    let f=try fresh("purpose-"+kind);f.helper.client.mode="unsupported";_=await failed(f)
    let dir=f.root.appendingPathComponent("push-psk-events"),url=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("stage-consent-")}!
    if kind=="open-mode" {precondition(chmod(url.path,0o644)==0)}
    if kind=="unknown-field" {var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];o["unknown"]=1;var data=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);data.append(10);try data.write(to:url);precondition(chmod(url.path,0o600)==0)}
    if kind=="symlink" {let saved=dir.appendingPathComponent("symlink-fixture-target");try FileManager.default.moveItem(at:url,to:saved);try FileManager.default.createSymbolicLink(at:url,withDestinationURL:saved)}
    if kind=="hardlink" {try FileManager.default.linkItem(at:url,to:dir.appendingPathComponent("hardlink-fixture-target"))}
    f.helper.client.mode="";let bad=await failed(f)
    a("unsafe-purpose-"+kind+"-denied-before-RPC",bad && f.helper.client.auths==1 && f.helper.client.replacements==0 && f.app.profileService.cache.saves==0)
   }catch{a("unsafe-purpose-"+kind+"-denied-before-RPC",false)}
  }
  print("pre_stage_client_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0:1)
 }
}
'''

HARNESS = H+'\n'+MAIN
if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='pre-stage-client-', dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
        d=Path(raw); (d/'main.swift').write_text(HARNESS); data=d/'app-data'; data.mkdir(mode=0o700)
        files=[S/'Models/VEXModels.swift']+[P/n for n in [
            'VPNProfileCache.swift','NativeAwgBoolean.swift','NativePSKIdentifier.swift',
            'NativePushPSKEventQueue.swift','NativePushSecureFileStore.swift','NativePSKStagedProfileStore.swift',
            'NativePSKRotationValidation.swift','NativeVPNProfileAuthorizationVerifier.swift','NativeAdmittedProfileStore.swift',
            'NativeProtectedReplacementCoordinator.swift','NativeProtectedPromotionStore.swift',
            'NativeProtectedRestartStore.swift','NativeProtectedRestartCoordinator.swift']]
        r=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,files),str(d/'main.swift'),'-o',str(d/'probe')],capture_output=True)
        sys.stdout.buffer.write(r.stdout); sys.stderr.buffer.write(r.stderr)
        if r.returncode: raise SystemExit(r.returncode)
        r=subprocess.run(['rtk','proxy',str(d/'probe'),str(data)],capture_output=True,timeout=120)
        sys.stdout.buffer.write(r.stdout); sys.stderr.buffer.write(r.stderr)
        names=[line.split(' ')[1].split('=')[0] for line in r.stdout.decode().splitlines() if line.startswith('pre_stage_client ')]
        if len(names)!=44 or len(set(names))!=44 or b'pre_stage_client_matrix cases=44 ' not in r.stdout: raise SystemExit(1)
        raise SystemExit(r.returncode)
