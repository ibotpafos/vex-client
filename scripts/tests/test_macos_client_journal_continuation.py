#!/usr/bin/env python3
"""Actual journal coordinator, custody/rebind, explicit App action and replay fence.
Owned disposable files; real signed material; inert authenticated root RPC ports.
No installer, live helper/app, DNS, API, key creation in the production path.
The ordinary-connect entry/cleanup fixture tests boundaries, not a live tunnel.
"""
from pathlib import Path
import os, runpy, subprocess, sys, tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / 'macos-native/Sources/VEXNativeMac'
P = S / 'Services'
CORE = [
 'source-restored-two-fresh-proofs-no-admission-cache-or-event-ACK',
 'candidate-resumed-commit-and-two-root-receipts-before-cache',
 'source-recover-lost-ACK-exact-explicit-retry-no-second-recover',
 'candidate-commit-lost-ACK-exact-explicit-retry-no-second-commit',
 'candidate-cache-failure-retains-bound-intent-proven-candidate',
 'candidate-cache-retry-after-consent-expiry-without-adoption',
 'candidate-first-receipt-denied-no-cache',
 'candidate-second-receipt-denied-no-cache',
 'source-first-proof-denied-retains-fence-and-custody',
 'source-second-proof-denied-retains-fence-and-custody',
 'source-choice-blocks-candidate-and-receipt-before-RPC',
 'journal-ACK-alone-never-rebinds-or-promotes',
 'receipt-ACK-cannot-enter-journal-path',
 'source-retry-healthy-candidate-denied',
 'candidate-retry-healthy-source-denied',
 'candidate-drains-only-exact-event-after-cache',
 'candidate-wait-is-bounded-at-40-no-admission',
 'candidate-wait-rechecks-current-intent',
 'journal-rebind-is-exact-idempotent-and-has-no-receipt',
 'journal-rebind-rejects-completed-receipt',
 'journal-rebind-rejects-foreign-tuple',
 'generic-load-still-rejects-cross-process-journal',
]
NEG = ['account', 'install', 'device', 'device-key', 'device-status', 'selection',
       'routing', 'paid', 'key-missing', 'stage-missing', 'same-process', 'consent-missing', 'consent-expired']
FAULT = ['unknown', 'duplicate', 'wrong-identity', 'empty-token', 'CRLF', 'oversize']
PHASES = ['transfer', 'snapshot', 'commit', 'receipt', 'recover', 'source-proof']
BOUNDARY = ['account-after-snapshot', 'token-after-commit', 'device-after-recover',
            'selection-after-recover', 'generation-after-receipt', 'signature-after-commit']
FENCE = ['fence-persists-through-store-reopen-and-secret-purge', 'fence-other-owner-isolated',
 'fence-exact-CAS-removal', 'fence-unknown-field-denied', 'fence-symlink-denied',
 'fence-hardlink-denied', 'fence-open-mode-denied', 'fence-oversize-denied',
 'unsafe-fence-custody-blocks-app-entry', 'preview-fence-query-does-no-filesystem-work',
 'ordinary-connect-entry-blocked-while-fenced', 'explicit-entry-selects-fresh-intent-marker',
 'busy-explicit-entry-no-connect', 'root-admission-required-before-fence-cleanup',
 'changed-intent-after-admission-retains-fence', 'stale-scope-after-admission-retains-fence',
 'exact-private-cleanup-after-new-admission-removes-fence-last',
 'source-proof-does-not-invent-admitted-profile']
WIRING = ['watchdog-gated-before-disconnect-and-after-await', 'background-entry-and-late-warmup-gated',
 'foreground-source-exit-forces-fresh-signed-profile', 'source-cleanup-never-prepares-connects-or-admits',
 'journal-coordinator-has-no-generic-network-ports', 'settings-actions-are-explicit',
 'source-fence-removal-only-follows-normal-root-admission']
NAMES = CORE + [a + '-reject-' + n for a in ['source', 'candidate'] for n in NEG]
NAMES += [p + '-reply-' + f + '-denied' for p in PHASES for f in FAULT]
NAMES += BOUNDARY + FENCE + WIRING

needed = {
 P/'NativeProtectedRestartCoordinator.swift': ['func transferJournal(', 'func restoreJournal(', 'func resumeJournal('],
 P/'NativeProtectedReplacementCoordinator.swift': ['struct JournalOwnership', 'reboundJournalIntent('],
 P/'NativeProtectedRestartStore.swift': ['struct SourceRestorationFence', 'func markSourceRestoration('],
 S/'Stores/VEXAppState.swift': ['func completeNativeProtectedSourceRestoration(', 'func connectAfterNativeProtectedSourceRestoration(']
}
if any(not p.exists() or any(x not in p.read_text() for x in markers) for p, markers in needed.items()):
 for name in NAMES: print('client_journal '+name+'=FAIL (explicit journal continuation absent)')
 print(f'client_journal_matrix cases={len(NAMES)} failures={len(NAMES)} live_network_commands=0')
 raise SystemExit(1)

# Reuse the exact signed-material fixture without replaying its completed cases.
# Frozen evaluators carry this sibling file, never load an old report as a task.
v = runpy.run_path(str(Path(__file__).with_name('test_macos_client_restart_material.py')), run_name='journal_fixture')
body = v['body']; app = v['app']; helper = v['helper']
H = v['HARNESS'].split('@main struct Main {', 1)[0]
start = H.index('@MainActor final class Client {')
end = H.index('@MainActor final class VEXHelperModel {', start)
CLIENT = r'''
@MainActor final class Client {
 unowned let app:AppState
 var calls:[String]=[],mode="journal",adoptions=0,proofs=0,snapshots=0,commits=0,recovers=0,displayReads=0,admissionProofs=0
 var pending=true,healthy="",fenceBeforeRecover=false
 let newOwner=String(repeating:"b",count:64)
 init(_ app:AppState){self.app=app}
 func fault(_ text:String,_ phase:String)->String {
  guard mode.hasPrefix(phase+"-reply-") else{return text}
  let f=String(mode.dropFirst((phase+"-reply-").count))
  if f=="unknown"{return String(text.dropLast())+" unknown=1\n"}
  if f=="duplicate"{let pair=text.split(separator:" ").first{$0.contains("=")}!;return String(text.dropLast())+" "+pair+"\n"}
  if f=="wrong-identity"{
   if text.contains(app.material.intent.transactionID){return text.replacingOccurrences(of:app.material.intent.transactionID,with:UUID().uuidString)}
   return text.replacingOccurrences(of:newOwner,with:app.material.intent.ownerTokenSHA256)
  }
  if f=="empty-token"{return text.replacingOccurrences(of:" ",with:"  ")}
  if f=="CRLF"{return String(text.dropLast())+"\r\n"}
  if f=="oversize"{return String(repeating:"x",count:4097)+"\n"}
  return text
 }
 func boundary(_ verb:String)throws {
  if mode=="account-after-snapshot" && verb=="snapshot"{app.session!.user.id="other"}
  if mode=="token-after-commit" && verb=="commit"{app.session!.accessToken="other"}
  if mode=="device-after-recover" && verb=="recover"{app.accountDevices=[]}
  if mode=="selection-after-recover" && verb=="recover"{app.selectedLocationId="us"}
  if mode=="generation-after-receipt" && verb=="receipt"{app.vpnOperationGeneration+=1}
  if mode=="signature-after-commit" && verb=="commit"{
   var e=try app.nativePSKStageStore.load(owner:app.owner,managedDeviceID:app.material.candidate.device.id,rotationID:app.material.rotationID)!.envelope
   e.profile.expiresAt=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-3600))
   try app.nativePSKStageStore.purge(owner:app.owner,managedDeviceID:app.material.candidate.device.id,rotationID:e.rotationID)
   try app.nativePSKStageStore.stage(e,owner:app.owner,managedDeviceID:app.material.candidate.device.id)
  }
 }
 func send(_ command:String,timeoutSeconds:Int)async throws->String {
  calls.append(command);let verb=String(command.split(separator:" ").first!),t=app.material.intent
  switch verb {
  case "protected-adopt-restart":
   adoptions+=1
   return fault("owner-transferred restart_protocol=1 transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(newOwner) evidence_kind=\(mode=="receipt-ACK" ? "receipt":"journal")\n","transfer")
  case "protected-snapshot":
   snapshots+=1;try boundary("snapshot")
   if mode=="journal-ACK-only"{throw ProbeError.injected}
   if mode=="source-first-proof-denied" && snapshots==3{throw ProbeError.injected}
   if mode=="source-second-proof-denied" && snapshots==4{throw ProbeError.injected}
   if pending{return fault("protected_protocol=1 recovery_pending=true transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(newOwner) commit_receipt_protocol=1\n","snapshot")}
   let text="protected_protocol=1 recovery_pending=false source_sha256=\(healthy) owner_token_sha256=\(newOwner) commit_receipt_protocol=1\n"
   return fault(text,snapshots>=3 && recovers>0 ? "source-proof":"snapshot")
  case "protected-recover":
   recovers+=1;fenceBeforeRecover=(try app.nativeProtectedRestartStore.sourceRestorationFence(owner:app.owner)) != nil
   pending=false;healthy=t.sourceSHA256;try boundary("recover")
   if mode=="recover-lost" && recovers==1{throw ProbeError.injected}
   return fault("recovered transaction_id=\(t.transactionID)\n","recover")
  case "protected-commit":
   commits+=1
   if mode=="waiting"{return "error: protected replacement awaiting fresh handshake\n"}
   pending=false;healthy=t.candidateSHA256;try boundary("commit")
   if mode=="commit-lost" && commits==1{throw ProbeError.injected}
   return fault("committed transaction_id=\(t.transactionID) candidate_sha256=\(t.candidateSHA256) latest_handshake=\(app.handshake)\n","commit")
  case "protected-receipt":
   proofs+=1;try boundary("receipt")
   if mode=="first-receipt-denied" && proofs==1{throw ProbeError.injected}
   if mode=="second-receipt-denied" && proofs==2{throw ProbeError.injected}
   return fault("committed commit_receipt_protocol=1 transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(newOwner) latest_handshake=\(app.handshake)\n","receipt")
  default:throw ProbeError.injected
  }
 }
}
'''
H = H[:start] + CLIENT + H[end:]
H = H.replace('func refreshStatus(quiet:Bool) async -> Bool {true}', '''func refreshStatus(quiet:Bool) async -> Bool {client.displayReads+=1;return true}
 func verifyAdmittedSource(_ hash:String,isCurrent:@escaping ()->Bool) async throws -> String {
  client.admissionProofs+=1
  if client.mode=="normal-proof-denied"{throw ProbeError.injected}
  if client.mode=="normal-proof-stale"{client.app.vpnOperationGeneration+=1}
  return client.newOwner
 }''', 1)
extra = '\n'.join(body(app, x).replace('private func ', 'func ', 1) for x in [
 '    private func completeNativeProtectedSourceRestoration(', '    private func rememberNativeAdmittedProfile(',
 '    func connectVPN(', '    func connectAfterNativeProtectedSourceRestoration('])
H = H.replace(' enum NativeProtectedRestartAction', r'''
 var nativeProtectedRestorationAdmissionGeneration:Int?,statusMessage:String?
 var connectEntries=0,explicitEntry=false,entryMarker:Int?
 func performConnectVPN(using helper:VEXHelperModel,generation:Int,explicitSourceRestoration:Bool=false)async {
  connectEntries+=1;explicitEntry=explicitSourceRestoration;entryMarker=nativeProtectedRestorationAdmissionGeneration
 }
 func ensureConnectStillDesired(generation:Int,sessionGeneration:Int?,accessToken:String?,accountID:String?)throws {
  guard desiredVpnState == .connected,generation==vpnOperationGeneration,sessionGeneration==authenticatedSessionGeneration,
   session?.accessToken==accessToken,session?.user.id==accountID else{throw AuthenticatedOperationError.sessionChanged}
 }
 EXTRA_METHODS
 enum NativeProtectedRestartAction'''.replace('EXTRA_METHODS',extra), 1)

H += r'''
@MainActor extension Fixture {
 func promotionURL()->URL {root.appendingPathComponent("push-psk-events").appendingPathComponent("promotion-"+NativeProtectedPromotionStore.fingerprint(["vex-protected-promotion-v1",app.owner.accountID,app.owner.installationID])+".json")}
 func journalize()throws {
  var o=try JSONSerialization.jsonObject(with:Data(contentsOf:promotionURL())) as! [String:Any];o.removeValue(forKey:"receipt")
  var d=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);d.append(10)
  try NativePushSecureFileStore(rootURL:root,maxBytes:16_384).write(d,name:promotionURL().lastPathComponent)
 }
 func capFile()->URL {try! FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("restart-capability-")}!}
 func expireCap()throws {
  let url=capFile();var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
  let now=UInt64(Date().timeIntervalSince1970);o["issuedAt"]=now-240;o["expiresAt"]=now-120
  var d=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);d.append(10)
  try d.write(to:url);precondition(chmod(url.path,0o600)==0)
 }
 func retained()throws->Bool {try app.nativeProtectedPromotionStore.hasRecord(accountID:app.owner.accountID,installationID:app.owner.installationID) && app.nativeProtectedRestartStore.loadMaterial(owner:app.owner) != nil}
 func noAdmission()->Bool {(try? app.nativeAdmittedProfiles.source(for:app.material.source.tunnel,scope:app.nativeAdmittedProfileScope(for:app.material.source.tunnel),helper:helper)) == nil}
 func event() -> NativePushPSKEvent {.init(kind:.cutover_ready,eventID:"matching-cutover",rotationID:envelope.rotationID,deviceID:source.device.id,profileVersion:2,deadlineAt:nil)}
 func dependencies()->NativeProtectedRestartCoordinator.Dependencies {
  .init(isCurrent:{self.app.session?.user.id==self.app.owner.accountID},validateMaterial:{
   _=try self.app.profileService.verifyProtectedRestartMaterial(self.app.material,verified:self.verified,owner:self.app.owner)
  },send:{cmd,timeout in try await self.helper.client.send(cmd,timeoutSeconds:timeout)},store:app.nativeProtectedRestartStore,owner:app.owner,material:app.material)
 }
 func bound()async throws -> (NativeProtectedReplacementCoordinator.RestartIntent,NativeProtectedReplacementCoordinator.Persistence) {
  let ownership=try await helper.transferProtectedJournal(dependencies())
  let p=try app.nativePSKPromotionPersistence(previous:source,next:app.material.candidate.tunnel,owner:app.owner,helper:helper,generation:11,sessionGeneration:4,token:"fixture-token")
  let d=try app.nativeProtectedPromotionStore.rebindJournalAfterAuthorizedRestart(accountID:app.owner.accountID,installationID:app.owner.installationID,original:app.material.intent,ownership:ownership,scopeFingerprint:p.scopeFingerprint,isCurrent:{true})
  return (try NativeProtectedReplacementCoordinator.restartIntent(d),p)
 }
 func change(_ mode:String)throws {
  if mode=="account"{app.session!.user.id="other"}
  if mode=="install"{app.nativePushIdentityStore.value="other"}
  if mode=="device"{app.accountDevices=[]}
  if mode=="device-key"{app.accountDevices[0].publicKey="other"}
  if mode=="device-status"{app.accountDevices[0].status="revoked"}
  if mode=="selection"{app.selectedLocationId="us"}
  if mode=="routing"{app.routingMode = .allExceptRu}
  if mode=="paid"{app.entitlement!.hasPaidAccess=false}
  if mode=="key-missing"{app.profileService.keyStore.pair=nil}
  if mode=="stage-missing"{try app.nativePSKStageStore.purge(owner:app.owner,managedDeviceID:source.device.id,rotationID:envelope.rotationID)}
  if mode=="consent-missing"{let cap=try app.nativeProtectedRestartStore.loadCapability(owner:app.owner,material:app.material)!;try app.nativeProtectedRestartStore.removeCapability(owner:app.owner,expected:cap)}
  if mode=="consent-expired"{try expireCap()}
 }
}
@main struct Main {
 @MainActor static func main()async {
  var names:[String]=[],failures=0
  func c(_ name:String,_ ok:Bool){names.append(name);if !ok{failures+=1};print("client_journal \(name)=\(ok ? "PASS":"FAIL")")}
  func run(_ name:String,_ operation:()async throws->Bool) async {
   do{c(name,try await operation())}catch{print("client_journal_fixture_error name=\(name) type=\(String(describing:type(of:error))) code=\((error as NSError).code)");c(name,false)}
  }
  await run("source-restored-two-fresh-proofs-no-admission-cache-or-event-ACK"){
   let f=try Fixture("source");try f.journalize();let e=f.event();try f.app.nativePushPSKQueue.enqueue(e,owner:f.app.owner)
   try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   return try f.helper.client.recovers==1 && f.helper.client.snapshots==4 && f.helper.client.proofs==0 && f.helper.client.commits==0
    && f.helper.client.fenceBeforeRecover && f.helper.client.displayReads==1 && f.app.profileService.cache.saves==0 && f.app.activeTunnel==nil
    && f.noAdmission() && f.app.nativePushPSKQueue.events(owner:f.app.owner)==[e] && f.app.hasNativeProtectedSourceRestorationFence
    && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
  }
  await run("candidate-resumed-commit-and-two-root-receipts-before-cache"){
   let f=try Fixture("candidate");try f.journalize();try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)
   return try f.helper.client.commits==1 && f.helper.client.proofs==2 && f.helper.client.recovers==0 && f.app.profileService.cache.saves==1
    && f.app.activeTunnel==f.app.material.candidate.tunnel && !f.app.hasNativeProtectedSourceRestorationFence && !f.retained()
  }
  for verb in ["recover","commit"] {
   await run(verb=="recover" ? "source-recover-lost-ACK-exact-explicit-retry-no-second-recover":"candidate-commit-lost-ACK-exact-explicit-retry-no-second-commit"){
    let f=try Fixture("lost-"+verb);try f.journalize();f.helper.client.mode=verb+"-lost"
    let action:AppState.NativeProtectedRestartAction=verb=="recover" ? .restoreSource:.resumeCandidate
    var denied=false;do{try await f.app.applyNativeProtectedRestart(action,helper:f.helper)}catch{denied=true}
    let retained=try f.retained();try await f.app.applyNativeProtectedRestart(action,helper:f.helper)
    return denied && retained && f.helper.client.adoptions==1 && (verb=="recover" ? f.helper.client.recovers==1 && f.app.hasNativeProtectedSourceRestorationFence:f.helper.client.commits==1 && f.helper.client.proofs==2)
   }
  }
  await run("candidate-cache-failure-retains-bound-intent-proven-candidate"){
   let f=try Fixture("cache");try f.journalize();f.app.profileService.cache.fail=true;var denied=false
   do{try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)}catch{denied=true}
   return try denied && f.retained() && f.helper.client.proofs==2 && f.app.activeTunnel==f.app.material.candidate.tunnel
    && f.app.nativeProtectedPromotionStore.restartIntent(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)?.processInstanceID==NativeProtectedReplacementCoordinator.processInstanceID
  }
  await run("candidate-cache-retry-after-consent-expiry-without-adoption"){
   let f=try Fixture("cache-expiry");try f.journalize();f.app.profileService.cache.fail=true
   do{try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)}catch{}
   try f.expireCap();f.app.profileService.cache.fail=false;try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)
   return f.helper.client.adoptions==1 && f.helper.client.commits==1 && f.helper.client.proofs==4 && f.app.profileService.cache.saves==2
  }
  for i in ["first","second"] {
   await run("candidate-"+i+"-receipt-denied-no-cache"){
    let f=try Fixture(i+"-receipt");try f.journalize();f.helper.client.mode=i+"-receipt-denied";var denied=false
    do{try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)}catch{denied=true}
    return try denied && f.retained() && f.app.profileService.cache.saves==0
   }
  }
  for i in ["first","second"] {
   await run("source-"+i+"-proof-denied-retains-fence-and-custody"){
    let f=try Fixture(i+"-source-proof");try f.journalize();f.helper.client.mode="source-"+i+"-proof-denied";var denied=false
    do{try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)}catch{denied=true}
    return try denied && f.retained() && f.app.hasNativeProtectedSourceRestorationFence && f.noAdmission() && f.app.profileService.cache.saves==0
   }
  }
  await run("source-choice-blocks-candidate-and-receipt-before-RPC"){
   let f=try Fixture("source-choice");try f.journalize();f.helper.client.mode="recover-lost"
   do{try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)}catch{}
   let before=f.helper.client.calls;var denied=0
   for a:AppState.NativeProtectedRestartAction in [.resumeCandidate,.recover]{do{try await f.app.applyNativeProtectedRestart(a,helper:f.helper)}catch{denied+=1}}
   return denied==2 && f.helper.client.calls==before && f.app.profileService.cache.saves==0
  }
  for mode in ["journal-ACK-only","receipt-ACK"] {
   await run(mode=="journal-ACK-only" ? "journal-ACK-alone-never-rebinds-or-promotes":"receipt-ACK-cannot-enter-journal-path"){
    let f=try Fixture(mode);try f.journalize();f.helper.client.mode=mode;var denied=false
    do{try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)}catch{denied=true}
    return try denied && f.app.nativeProtectedPromotionStore.restartIntent(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)==f.app.material.intent && f.app.profileService.cache.saves==0 && f.helper.client.commits==0
   }
  }
  for source in [true,false] {
   await run(source ? "source-retry-healthy-candidate-denied":"candidate-retry-healthy-source-denied"){
    let f=try Fixture(source ? "source-wrong-healthy":"candidate-wrong-healthy");try f.journalize();let (t,p)=try await f.bound()
    f.helper.client.pending=false;f.helper.client.healthy=source ? t.candidateSHA256:t.sourceSHA256;var denied=false
    do{if source{try await f.helper.protectedRestart.restoreJournal(t,persistence:p,dependencies:f.dependencies())}
       else{_=try await f.helper.protectedRestart.resumeJournal(t,persistence:p,dependencies:f.dependencies(),wait:{})}}catch{denied=true}
    return try denied && f.retained() && f.helper.client.recovers==0 && f.helper.client.commits==0 && f.app.profileService.cache.saves==0
   }
  }
  await run("candidate-drains-only-exact-event-after-cache"){
   let f=try Fixture("exact-events");try f.journalize();let match=f.event()
   let other=NativePushPSKEvent(kind:.cutover_ready,eventID:"other-version",rotationID:f.envelope.rotationID,deviceID:f.source.device.id,profileVersion:3,deadlineAt:nil)
   for e in [match,other]{try f.app.nativePushPSKQueue.enqueue(e,owner:f.app.owner)}
   try await f.app.applyNativeProtectedRestart(.resumeCandidate,helper:f.helper)
   return try f.app.nativePushPSKQueue.events(owner:f.app.owner)==[other] && f.helper.client.proofs==2 && f.app.profileService.cache.saves==1
  }
  for change in [false,true] {
   await run(change ? "candidate-wait-rechecks-current-intent":"candidate-wait-is-bounded-at-40-no-admission"){
    let f=try Fixture(change ? "wait-current":"wait-limit");try f.journalize();let (t,p)=try await f.bound();f.helper.client.mode="waiting";var denied=false,waits=0
    do{_=try await f.helper.protectedRestart.resumeJournal(t,persistence:p,dependencies:f.dependencies(),wait:{waits+=1;if change{f.app.session!.user.id="other"}})}catch{denied=true}
    return try denied && f.retained() && f.helper.client.commits==(change ? 1:40) && waits==(change ? 1:40) && f.helper.client.proofs==0
   }
  }
  await run("journal-rebind-is-exact-idempotent-and-has-no-receipt"){
   let f=try Fixture("idempotent");try f.journalize();let (t,p)=try await f.bound(),before=try p.load()!
   let o=NativeProtectedReplacementCoordinator.JournalOwnership(transactionID:t.transactionID,sourceSHA256:t.sourceSHA256,candidateSHA256:t.candidateSHA256,ownerTokenSHA256:t.ownerTokenSHA256)
   let after=try f.app.nativeProtectedPromotionStore.rebindJournalAfterAuthorizedRestart(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID,original:f.app.material.intent,ownership:o,scopeFingerprint:p.scopeFingerprint,isCurrent:{true})
   return try after==before && NativeProtectedReplacementCoordinator.restartReceiptMetadata(after)==nil
  }
  for mode in ["completed","foreign"] {
   await run(mode=="completed" ? "journal-rebind-rejects-completed-receipt":"journal-rebind-rejects-foreign-tuple"){
    let f=try Fixture("rebind-"+mode);if mode=="foreign"{try f.journalize()}
    let original=f.app.material.intent,o=NativeProtectedReplacementCoordinator.JournalOwnership(transactionID:mode=="foreign" ? UUID().uuidString:original.transactionID,sourceSHA256:original.sourceSHA256,candidateSHA256:original.candidateSHA256,ownerTokenSHA256:f.helper.client.newOwner)
    let before=try Data(contentsOf:f.promotionURL());var denied=false
    do{_=try f.app.nativeProtectedPromotionStore.rebindJournalAfterAuthorizedRestart(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID,original:original,ownership:o,scopeFingerprint:NativeProtectedReplacementCoordinator.digest("new-scope"),isCurrent:{true})}catch{denied=true}
    return try denied && Data(contentsOf:f.promotionURL())==before
   }
  }
  await run("generic-load-still-rejects-cross-process-journal"){
   let f=try Fixture("generic");try f.journalize();var denied=false
   do{try NativeProtectedReplacementCoordinator.requireValidPersistentPayload(Data(contentsOf:f.promotionURL()),scopeFingerprint:f.app.material.intent.scopeFingerprint,generation:11)}catch{denied=true}
   return denied && f.helper.client.calls.isEmpty
  }
  for action in ["source","candidate"] {for mode in NEGATIVES {
   await run(action+"-reject-"+mode){
    let f=try Fixture(action+"-"+mode,oldProcess:mode != "same-process");try f.journalize();try f.change(mode);var denied=false
    do{try await f.app.applyNativeProtectedRestart(action=="source" ? .restoreSource:.resumeCandidate,helper:f.helper)}catch{denied=true}
    return denied && f.helper.client.calls.isEmpty && f.app.profileService.cache.saves==0 && f.noAdmission()
   }
  }}
  for phase in PHASES {for fault in FAULTS {
   await run(phase+"-reply-"+fault+"-denied"){
    let f=try Fixture(phase+"-"+fault);try f.journalize();f.helper.client.mode=phase+"-reply-"+fault;var denied=false
    do{try await f.app.applyNativeProtectedRestart(["recover","source-proof"].contains(phase) ? .restoreSource:.resumeCandidate,helper:f.helper)}catch{denied=true}
    return try denied && f.retained() && f.app.profileService.cache.saves==0 && f.noAdmission()
   }
  }}
  for mode in BOUNDARIES {
   await run(mode){
    let f=try Fixture(mode);try f.journalize();f.helper.client.mode=mode;var denied=false
    do{try await f.app.applyNativeProtectedRestart(mode.hasSuffix("after-recover") ? .restoreSource:.resumeCandidate,helper:f.helper)}catch{denied=true}
    return try denied && f.retained() && f.app.profileService.cache.saves==0
   }
  }
  await run("fence-persists-through-store-reopen-and-secret-purge"){
   let f=try Fixture("fence-reopen");try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   let before=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)!
   try f.app.nativeProtectedRestartStore.purge(owner:f.app.owner)
   return try NativeProtectedRestartStore(appDataURL:f.root).sourceRestorationFence(owner:f.app.owner)==before
  }
  await run("fence-other-owner-isolated"){
   let f=try Fixture("fence-owner");try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   return try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:.init(accountID:"other",installationID:"fixture-install")!)==nil && f.app.hasNativeProtectedSourceRestorationFence
  }
  await run("fence-exact-CAS-removal"){
   let f=try Fixture("fence-CAS");try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   let v=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)!,bad=NativeProtectedRestartStore.SourceRestorationFence(schema:v.schema,namespace:v.namespace,ownerFingerprint:v.ownerFingerprint,original:v.original,journalIntent:v.journalIntent,materialSHA256:String(repeating:"a",count:64));var denied=false
   do{try f.app.nativeProtectedRestartStore.removeSourceRestorationFence(owner:f.app.owner,expected:bad)}catch{denied=true}
   return try denied && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==v
  }
  for mode in ["unknown-field","symlink","hardlink","open-mode","oversize"] {
   await run("fence-"+mode+"-denied"){
    let f=try Fixture("fence-"+mode);try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
    let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("source-restoration-")}!
    if mode=="unknown-field"{var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];o["extra"]=true;var d=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);d.append(10);try d.write(to:url);precondition(chmod(url.path,0o600)==0)}
    if mode=="symlink"{let dest=f.root.appendingPathComponent("external");try FileManager.default.moveItem(at:url,to:dest);precondition(symlink(dest.path,url.path)==0)}
    if mode=="hardlink"{precondition(link(url.path,f.root.appendingPathComponent("extra-link").path)==0)}
    if mode=="open-mode"{precondition(chmod(url.path,0o644)==0)}
    if mode=="oversize"{try Data(repeating:0,count:16_385).write(to:url);precondition(chmod(url.path,0o600)==0)}
    var denied=false;do{_=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)}catch{denied=true}
    return denied && f.app.hasNativeProtectedSourceRestorationFence
   }
  }
  await run("unsafe-fence-custody-blocks-app-entry"){
   let f=try Fixture("unsafe-fence");try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("source-restoration-")}!
   precondition(chmod(url.path,0o644)==0);await f.app.connectVPN(using:f.helper)
   return f.app.connectEntries==0 && f.app.hasNativeProtectedSourceRestorationFence
  }
  await run("preview-fence-query-does-no-filesystem-work"){
   let f=try Fixture("preview");f.app.nativePushRuntimeAllowed=false
   let before=try FileManager.default.contentsOfDirectory(atPath:f.root.path)
   return try !f.app.hasNativeProtectedSourceRestorationFence && FileManager.default.contentsOfDirectory(atPath:f.root.path)==before
  }
  for mode in ["ordinary","explicit","busy"] {
   await run(mode=="ordinary" ? "ordinary-connect-entry-blocked-while-fenced":mode=="explicit" ? "explicit-entry-selects-fresh-intent-marker":"busy-explicit-entry-no-connect"){
    let f=try Fixture("entry-"+mode);try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
    if mode=="ordinary"{await f.app.connectVPN(using:f.helper)}else{if mode=="busy"{f.helper.isBusy=true};await f.app.connectAfterNativeProtectedSourceRestoration(using:f.helper)}
    return mode=="explicit" ? f.app.connectEntries==1 && f.app.explicitEntry && f.app.entryMarker==f.app.vpnOperationGeneration && f.app.nativeProtectedRestorationAdmissionGeneration==nil:f.app.connectEntries==0
   }
  }
  for mode in ["denied","changed","stale","good"] {
   let name=mode=="denied" ? "root-admission-required-before-fence-cleanup":mode=="changed" ? "changed-intent-after-admission-retains-fence":mode=="stale" ? "stale-scope-after-admission-retains-fence":"exact-private-cleanup-after-new-admission-removes-fence-last"
   await run(name){
    let f=try Fixture("admission-"+mode);try f.journalize();f.helper.client.mode="recover-lost"
    do{try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)}catch{}
    f.app.desiredVpnState = .connected;f.app.nativeProtectedRestorationAdmissionGeneration=f.app.vpnOperationGeneration
    if mode=="denied"{f.helper.client.mode="normal-proof-denied"}
    if mode=="stale"{f.helper.client.mode="normal-proof-stale"}
    if mode=="changed"{try f.journalize() /* replace exact bound intent with original: cleanup must reject */
     var o=try JSONSerialization.jsonObject(with:Data(contentsOf:f.promotionURL())) as! [String:Any];var t=o["transaction"] as! [String:Any];t["candidate"]=String(repeating:"d",count:64);o["transaction"]=t
     var d=try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]);d.append(10);try d.write(to:f.promotionURL());precondition(chmod(f.promotionURL().path,0o600)==0)
    }
    await f.app.rememberNativeAdmittedProfile(f.app.material.candidate.tunnel,canonicalConfig:f.app.material.candidateConfig,helper:f.helper,generation:f.app.vpnOperationGeneration,sessionGeneration:4,accessToken:"fixture-token",accountID:"fixture-account")
    return mode=="good" ? (try !f.app.hasNativeProtectedSourceRestorationFence && !f.retained() && f.helper.client.admissionProofs==1):f.app.hasNativeProtectedSourceRestorationFence
   }
  }
  await run("source-proof-does-not-invent-admitted-profile"){
   let f=try Fixture("source-not-admission");try f.journalize();try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)
   return f.noAdmission() && f.helper.client.admissionProofs==0 && f.app.activeTunnel==nil
  }
  print("client_journal_runtime_matrix cases=\(names.count) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0:1)
 }
}
'''
for token, values in [('NEGATIVES',NEG),('PHASES',PHASES),('FAULTS',FAULT),('BOUNDARIES',BOUNDARY)]:
 H = H.replace(token,repr(values).replace("'",'"'))
with tempfile.TemporaryDirectory(prefix='client-journal-',dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
 d=Path(raw);(d/'main.swift').write_text(H);data=d/'data';data.mkdir(mode=0o700)
 files=[S/'Models/VEXModels.swift']+[P/n for n in ['VPNProfileCache.swift','NativeAwgBoolean.swift','NativePSKIdentifier.swift','NativePushPSKEventQueue.swift','NativePushSecureFileStore.swift','NativePSKStagedProfileStore.swift','NativePSKRotationValidation.swift','NativeVPNProfileAuthorizationVerifier.swift','NativeAdmittedProfileStore.swift','NativeProtectedReplacementCoordinator.swift','NativeProtectedPromotionStore.swift','NativeProtectedRestartStore.swift','NativeProtectedRestartCoordinator.swift']]
 r=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,files),str(d/'main.swift'),'-o',str(d/'probe')],capture_output=True)
 sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
 if r.returncode:raise SystemExit(r.returncode)
 r=subprocess.run(['rtk','proxy',str(d/'probe'),str(data)],capture_output=True,timeout=120)
 sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
 failures=r.returncode
 action=body(app,'    private func applyNativeProtectedRestart(')
 watchdog=body(app,'    func recoverTunnelIfNeeded(')
 warmup=body(app,'    private func scheduleProfileWarmup(')
 cleanup=body(app,'    private func completeNativeProtectedSourceRestoration(')
 source=action[action.index('            if action == .restoreSource {'):action.index('            } else {',action.index('            if action == .restoreSource {'))]
 normal=body(app,'    private func performConnectVPN(')
 remember=body(app,'    private func rememberNativeAdmittedProfile(')
 coordinator=(P/'NativeProtectedRestartCoordinator.swift').read_text()
 ui=(S/'Views/VEXSettingsView.swift').read_text()
 checks=[
  watchdog.index('hasNativeProtectedSourceRestorationFence')<watchdog.index('autopilotService.usage') and watchdog.count('hasNativeProtectedSourceRestorationFence')>=3,
  all('hasNativeProtectedSourceRestorationFence' in body(app,x) for x in ['    private func processNativePSKEvents(', '    private func processNativeNormalPendingProfile(', '    private func reconcileNativePushSession(', '    private func scheduleProfileWarmup(', '    private func prepareSelectedProfile(']) and warmup.count('hasNativeProtectedSourceRestorationFence')>=4,
  'forceRefresh: explicitSourceRestoration' in normal and normal.index('hasNativeProtectedSourceRestorationFence')<normal.index('authenticatedAccessToken'),
  not any(x in source for x in ['promoteStagedPSKProfile','nativeAdmittedProfiles.record','activeTunnel = material.source','connectVPN(','prepareSelectedProfile','nativePushPSKQueue.remove']),
  not any(x in coordinator for x in ['ensureHelperReady','disconnect(','resolveProfile','writeHelperConfig','acknowledgePSK','attachOwnerWatchdog']),
  all(x in ui for x in ['restoreNativeProtectedSource','resumeNativeProtectedCandidate','connectAfterNativeProtectedSourceRestoration']),
  remember.index('verifyAdmittedSource')<remember.index('nativeAdmittedProfiles.record')<remember.index('completeNativeProtectedSourceRestoration') and cleanup.index('finishNativeProtectedPrivateRetirement' if 'finishNativeProtectedPrivateRetirement' in cleanup else 'removeMaterial')<cleanup.index('removeSourceRestorationFence')
 ]
 for name,ok in zip(WIRING,checks):print('client_journal '+name+'='+('PASS' if ok else 'FAIL'));failures+=not ok
 seen=[x.split(' ')[1].split('=')[0] for x in r.stdout.decode().splitlines() if x.startswith('client_journal ')]+WIRING
 if seen!=NAMES:print('client_journal case_order_or_coverage=FAIL');failures+=1
 count=sum('=FAIL' in x for x in r.stdout.decode().splitlines() if x.startswith('client_journal '))+sum(not x for x in checks)
 print(f'client_journal_matrix cases={len(seen)} failures={count} live_network_commands=0')
 raise SystemExit(0 if not failures else 1)
