#!/usr/bin/env python3
"""Actual App cancel/coordinators and descriptor-owned private retirement IO.

RPC uses the existing inert idempotent root-cancel fixture; root cancellation
authority has its separate compiled matrix. Deterministic IO exceptions and
fresh store instances are NOT actual OS crash/power-loss/installed acceptance.
"""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"
P = S / "Services"
if "struct StageCancellationRetirement" not in (P / "NativeProtectedRestartStore.swift").read_text():
    print("stage_cancel_retirement contract=ABSENT (one diagnostic; durable private retirement missing; runtime branches NOT executed)")
    print("stage_cancel_retirement_matrix cases=1 failures=1 live_network_commands=0")
    raise SystemExit(1)

v = runpy.run_path(str(Path(__file__).with_name("test_macos_pre_stage_cancel_client.py")), run_name="retirement_fixture")
H = v["H"].replace("let nativeProtectedRestartStore:", "var nativeProtectedRestartStore:")
MAIN = r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0,names=Set<String>()
  func a(_ name:String,_ ok:Bool){cases+=1;let unique=names.insert(name).inserted;if !ok || !unique{failures+=1};print("stage_cancel_retirement \(name)=\(ok && unique ? "PASS":"FAIL")")}
  func path(_ f:Fixture,_ prefix:String)throws->URL {
   guard let u=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(prefix)})else{throw ProbeError.injected};return u
  }
  func write(_ object:[String:Any],_ url:URL)throws {
   var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);try data.write(to:url);precondition(chmod(url.path,0o600)==0)
  }
  func reopen(_ f:Fixture){f.app.nativeProtectedRestartStore = .init(appDataURL:f.root)}
  func denied(_ f:Fixture,_ action:AppState.NativeProtectedRestartAction = .cancel)async->Bool {
   do{try await f.app.applyNativeProtectedRestart(action,helper:f.helper);return false}catch{return true}
  }
  func inert(_ f:Fixture)->Bool {
   f.helper.client.replacements==0 && f.helper.client.commits==0 && f.helper.client.proofs==0 && f.helper.client.recoveries==0
    && !f.helper.client.calls.contains{$0.hasPrefix("protected-adopt") || $0.hasPrefix("protected-authorize-restart")}
    && f.app.profileService.cache.saves==0 && f.app.activeTunnel?.profileVersion==1 && VPNProfileService.dnsCalls==0
  }
  func clean(_ f:Fixture)throws->Bool {
   try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil
    && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
    && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)?.phase=="retired" && inert(f)
  }
  func fresh(_ label:String)async throws->Fixture {
   let f=try Fixture(label,oldProcess:false)
   try f.app.nativeProtectedRestartStore.removeMaterial(owner:f.app.owner,expected:f.app.material)
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.activeTunnel=f.source;f.app.nativePSKPreparedTunnel=f.source;f.app.desiredVpnState = .connected
   f.app.nativeProtectedStageConsentEnabled=true;f.app.vpnOperationGeneration=11
   f.app.profileService.canonicalCandidate=f.app.material.candidateConfig
   _=try f.app.nativeAdmittedProfiles.record(tunnel:f.source,canonicalConfig:f.app.material.sourceConfig,
     ownerTokenSHA256:f.app.material.intent.ownerTokenSHA256,scope:try f.app.nativeAdmittedProfileScope(for:f.source),helper:f.helper)
   f.helper.client.mode="lost-authorize"
   var bad=false;do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)}catch{bad=true}
   guard bad,f.helper.client.authorized,f.helper.client.replacements==0 else{throw ProbeError.injected}
   f.helper.client.mode="";return f
  }
  func stopped(_ label:String)async throws->Fixture {
   let f=try await fresh(label)
   f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{step in if step=="before-capability-remove"{throw ProbeError.injected}})
   guard await denied(f),try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)?.phase=="retiring" else{throw ProbeError.injected}
   reopen(f);return f
  }
  let steps=["before-retirement-write","after-retirement-write","after-retirement-readback","before-capability-remove","after-capability-remove","before-purpose-remove","after-purpose-remove","before-material-remove","after-material-remove","before-retired-write","after-retired-write","after-retired-readback"]
  for step in steps {
   do {
    let f=try await fresh("boundary-"+step),cap=try path(f,"restart-capability-")
    let cb=try Data(contentsOf:cap),material=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
    var fired=false
    f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step && !fired{fired=true;throw ProbeError.injected}})
    let bad=await denied(f),proof=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)
    let walExpected=step != "before-retirement-write"
    let capUnchanged = try !FileManager.default.fileExists(atPath:cap.path) || Data(contentsOf:cap)==cb
    a(step+"-observed-real-IO-boundary-preserves-terminal-custody",bad && fired && (proof != nil)==walExpected && capUnchanged && f.helper.client.cancels==1 && inert(f))
    reopen(f);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    let wal=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)!
    var regenerated=0,blocked=false
    do{_=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:material,now:UInt64(Date().timeIntervalSince1970)+121,generate:{regenerated+=1;return String(repeating:"1",count:64)})}catch{blocked=true}
    a(step+"-fresh-store-exact-retry-no-RPC-TTL-or-admission",try clean(f) && f.helper.client.cancels==1 && f.helper.client.auths==1 && wal.stage.intent==material.intent && blocked && regenerated==0)
   }catch{a(step+"-observed-real-IO-boundary-preserves-terminal-custody",false);a(step+"-fresh-store-exact-retry-no-RPC-TTL-or-admission",false)}
  }
  for field in ["schema","namespace","stageSHA256","acknowledgementSHA256","capabilitySHA256","phase","unknown","oversize"] {
   do {
    let f=try await stopped("strict-"+field),wal=try path(f,"stage-retirement-"),cap=try path(f,"restart-capability-"),nonce=try path(f,"promotion-"),mat=try path(f,"restart-material-")
    let wb=try Data(contentsOf:wal),cb=try Data(contentsOf:cap),nb=try Data(contentsOf:nonce),mb=try Data(contentsOf:mat)
    var object=try JSONSerialization.jsonObject(with:wb) as! [String:Any]
    switch field {
    case "schema":object[field]=2
    case "namespace":object[field]="unknown"
    case "stageSHA256","acknowledgementSHA256":object[field]=String(repeating:"0",count:64)
    case "capabilitySHA256":object[field]="not-a-digest"
    case "phase":object[field]="authorized"
    case "unknown":object[field]=true
    default:object[field]=String(repeating:"x",count:16385)
    }
    try write(object,wal);let bad=await denied(f)
    a("strict-WAL-"+field+"-fail-closed-no-delete-or-authority",try bad && Data(contentsOf:cap)==cb && Data(contentsOf:nonce)==nb && Data(contentsOf:mat)==mb && f.helper.client.cancels==1 && inert(f))
    try wb.write(to:wal);precondition(chmod(wal.path,0o600)==0);reopen(f)
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    a("strict-WAL-"+field+"-original-proof-retry-only",try clean(f) && f.helper.client.cancels==1)
   }catch{a("strict-WAL-"+field+"-fail-closed-no-delete-or-authority",false);a("strict-WAL-"+field+"-original-proof-retry-only",false)}
  }
  for mode in ["mode","symlink","hardlink","directory"] {
   do {
    let f=try await stopped("owned-"+mode),wal=try path(f,"stage-retirement-"),nonce=try path(f,"promotion-")
    let wb=try Data(contentsOf:wal),nb=try Data(contentsOf:nonce),outside=f.root.appendingPathComponent("outside-fixture")
    try Data("outside-unchanged".utf8).write(to:outside)
    switch mode {
    case "mode":precondition(chmod(wal.path,0o644)==0)
    case "symlink":try FileManager.default.removeItem(at:wal);try FileManager.default.createSymbolicLink(at:wal,withDestinationURL:outside)
    case "hardlink":precondition(link(wal.path,outside.appendingPathExtension("link").path)==0)
    default:try FileManager.default.removeItem(at:wal);try FileManager.default.createDirectory(at:wal,withIntermediateDirectories:false)
    }
    let bad=await denied(f)
    a("owned-WAL-"+mode+"-refused-no-external-or-nonce-write",try bad && Data(contentsOf:outside)==Data("outside-unchanged".utf8) && Data(contentsOf:nonce)==nb && f.helper.client.cancels==1)
    if mode=="hardlink"{try FileManager.default.removeItem(at:outside.appendingPathExtension("link"))}
    if mode=="symlink" || mode=="directory"{try FileManager.default.removeItem(at:wal)}
    try wb.write(to:wal);precondition(chmod(wal.path,0o600)==0);reopen(f)
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    a("owned-WAL-"+mode+"-exact-owned-retry",try clean(f) && f.helper.client.cancels==1)
   }catch{a("owned-WAL-"+mode+"-refused-no-external-or-nonce-write",false);a("owned-WAL-"+mode+"-exact-owned-retry",false)}
  }
  for prefix in ["restart-capability-","stage-consent-","restart-material-"] {
   do {
    let f=try await stopped("drift-"+prefix),file=try path(f,prefix),nonce=try path(f,"promotion-")
    let original=try Data(contentsOf:file),nb=try Data(contentsOf:nonce)
    var object=try JSONSerialization.jsonObject(with:original) as! [String:Any]
    if prefix=="restart-capability-"{object["value"]=String(repeating:"e",count:64)}
    if prefix=="stage-consent-"{object["cancelled"]=false}
    if prefix=="restart-material-"{object["selectedLocationID"]="changed"}
    try write(object,file);let bad=await denied(f)
    a(prefix+"pinned-custody-drift-retains-nonce-no-admission",try bad && Data(contentsOf:nonce)==nb && f.helper.client.cancels==1 && inert(f))
    try original.write(to:file);precondition(chmod(file.path,0o600)==0);reopen(f)
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    a(prefix+"pinned-custody-exact-restoration-retry",try clean(f) && f.helper.client.cancels==1)
   }catch{a(prefix+"pinned-custody-drift-retains-nonce-no-admission",false);a(prefix+"pinned-custody-exact-restoration-retry",false)}
  }
  do {
   let f=try await fresh("missing-purpose"),purpose=try path(f,"stage-consent-"),cap=try path(f,"restart-capability-")
   let m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!,cb=try Data(contentsOf:cap)
   try FileManager.default.removeItem(at:purpose);var generated=0,blocked=false
   do{_=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:m,now:UInt64(Date().timeIntervalSince1970),generate:{generated+=1;return String(repeating:"1",count:64)})}catch{blocked=true}
   a("immutable-required-purpose-absence-does-not-change-protocol",try m.stagePurposeRequired==true && blocked && generated==0 && Data(contentsOf:cap)==cb)
   try FileManager.default.removeItem(at:cap);let before=f.helper.client.calls.count,bad=await denied(f,.authorize)
   a("missing-purpose-and-capability-no-local-TTL-or-post-journal-RPC",try bad && f.helper.client.calls.count==before && f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)==nil && inert(f))
  }catch{a("immutable-required-purpose-absence-does-not-change-protocol",false);a("missing-purpose-and-capability-no-local-TTL-or-post-journal-RPC",false)}
  for phase in [true,false] {
   do {
    let f=try Fixture("legacy-phase-"+String(phase),oldProcess:false),nonce=try path(f,"promotion-")
    var object=try JSONSerialization.jsonObject(with:Data(contentsOf:nonce)) as! [String:Any],t=object["transaction"] as! [String:Any]
    object.removeValue(forKey:"receipt");t["stageConsentPending"]=phase;t["commitResponseUncertain"]=false;object["transaction"]=t;try write(object,nonce)
    let bad=await denied(f,.authorize)
    a("legacy-material-nonce-purpose-"+String(phase)+"-missing-marker-no-renewal",try bad && f.app.material.stagePurposeRequired==nil && f.helper.client.calls.isEmpty && f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:f.app.material)==nil)
   }catch{a("legacy-material-nonce-purpose-"+String(phase)+"-missing-marker-no-renewal",false)}
  }
  do {
   let f=try await fresh("consumed"),nonce=try path(f,"promotion-")
   var object=try JSONSerialization.jsonObject(with:Data(contentsOf:nonce)) as! [String:Any],t=object["transaction"] as! [String:Any];t["stageConsentPending"]=false;object["transaction"]=t;try write(object,nonce)
   let nb=try Data(contentsOf:nonce),bad=await denied(f),wal=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)!
   a("conservative-consumed-intent-veto-retains-material-and-WAL",try bad && Data(contentsOf:nonce)==nb && wal.phase=="retiring" && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil && inert(f))
   reopen(f);let retry=await denied(f)
   a("consumed-intent-fresh-store-retry-no-RPC-or-phase-reversal",try retry && Data(contentsOf:nonce)==nb && f.helper.client.cancels==1 && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)==wal)
  }catch{a("conservative-consumed-intent-veto-retains-material-and-WAL",false);a("consumed-intent-fresh-store-retry-no-RPC-or-phase-reversal",false)}
  do {
   let f=try await stopped("store-nonce-veto"),wal=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)!,nonce=try path(f,"promotion-"),nb=try Data(contentsOf:nonce)
   var bad=false;do{try f.app.nativeProtectedRestartStore.finishStageCancellation(owner:f.app.owner,expected:wal,isCurrent:{true})}catch{bad=true}
   a("store-finisher-itself-requires-exact-nonce-removal-first",try bad && Data(contentsOf:nonce)==nb && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)==wal)
  }catch{a("store-finisher-itself-requires-exact-nonce-removal-first",false)}
  for step in ["before-retired-write","after-retired-write"] {
   do {
    let f=try await fresh("reappearance-"+step),cap=try path(f,"restart-capability-"),cb=try Data(contentsOf:cap)
    var fired=false
    f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step && !fired{fired=true;try cb.write(to:cap);precondition(chmod(cap.path,0o600)==0)}})
    let bad=await denied(f),wal=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)!
    var generated=0,authorityDenied=false
    do{_=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:f.app.material,now:UInt64(Date().timeIntervalSince1970),generate:{generated+=1;return String(repeating:"1",count:64)})}catch{authorityDenied=true}
    a(step+"-reappeared-pinned-secret-no-false-completion",try bad && fired && Data(contentsOf:cap)==cb && authorityDenied && generated==0 && inert(f))
    reopen(f);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    a(step+"-reappearance-exact-private-retry-not-authority",try clean(f) && wal.stage.intent.transactionID==f.app.material.intent.transactionID && f.helper.client.cancels==1)
   }catch{a(step+"-reappeared-pinned-secret-no-false-completion",false);a(step+"-reappearance-exact-private-retry-not-authority",false)}
  }
  do {
   let f=try await fresh("current-withdrawal")
   f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{step in if step=="after-purpose-remove"{f.app.session!.accessToken="withdrawn"}})
   let bad=await denied(f)
   a("current-withdrawal-after-first-delete-retains-material-WAL",try bad && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)?.phase=="retiring" && inert(f))
   f.app.session!.accessToken="fixture-token";reopen(f);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("current-original-owner-restored-retry-only-no-RPC",try clean(f) && f.helper.client.cancels==1)
  }catch{a("current-withdrawal-after-first-delete-retains-material-WAL",false);a("current-original-owner-restored-retry-only-no-RPC",false)}
  for field in ["process","account","installation"] {
   do {
    let f=try await stopped("foreign-"+field),wal=try path(f,"stage-retirement-"),original=try Data(contentsOf:wal)
    if field=="account"{f.app.session!.user.id="other"}
    if field=="installation"{f.app.nativePushIdentityStore.value="other"}
    if field=="process" {
     var object=try JSONSerialization.jsonObject(with:original) as! [String:Any],stage=object["stage"] as! [String:Any],intent=stage["intent"] as! [String:Any]
     intent["processInstanceID"]=UUID().uuidString;stage["intent"]=intent;object["stage"]=stage
     var sb=try JSONSerialization.data(withJSONObject:stage,options:[.sortedKeys]);sb.append(10)
     object["stageSHA256"]=NativeProtectedReplacementCoordinator.digest(String(decoding:sb,as:UTF8.self));try write(object,wal)
    }
    let before=try Data(contentsOf:wal),bad=await denied(f)
    a("foreign-"+field+"-cannot-clean-transfer-or-admit",try bad && Data(contentsOf:wal)==before && f.helper.client.cancels==1 && inert(f))
   }catch{a("foreign-"+field+"-cannot-clean-transfer-or-admit",false)}
  }
  do {
   let f=try await fresh("source-fence"),m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!,t=m.intent
   let journal=NativeProtectedReplacementCoordinator.RestartIntent(transactionID:t.transactionID,sourceSHA256:t.sourceSHA256,candidateSHA256:t.candidateSHA256,ownerTokenSHA256:String(repeating:"b",count:64),scopeFingerprint:t.scopeFingerprint,processInstanceID:t.processInstanceID,generation:t.generation)
   try f.app.nativeProtectedRestartStore.markSourceRestoration(owner:f.app.owner,material:m,journalIntent:journal)
   let fence=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("private-retirement-does-not-remove-source-replay-fence",try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==fence && fence != nil)
  }catch{a("private-retirement-does-not-remove-source-replay-fence",false)}
  do {
   let f=try await stopped("purge-proof"),wal=try path(f,"stage-retirement-"),wb=try Data(contentsOf:wal)
   try f.app.nativeProtectedRestartStore.purge(owner:f.app.owner)
   let retained=try Data(contentsOf:wal)==wb
   reopen(f);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("explicit-secret-purge-preserves-terminal-metadata-exact-retry",try retained && clean(f) && f.helper.client.cancels==1)
  }catch{a("explicit-secret-purge-preserves-terminal-metadata-exact-retry",false)}
  do {
   let f=try await fresh("terminal-provenance"),m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!,cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)!
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   let wal=try path(f,"stage-retirement-"),bytes=try Data(contentsOf:wal),text=String(decoding:bytes,as:UTF8.self)
   a("terminal-canonical-bounded-metadata-has-no-secret-or-TTL",try bytes.count<=16384 && !text.contains(cap.value) && !text.contains(m.sourceConfig) && !text.contains(m.candidateConfig) && !text.contains(f.app.owner.accountID) && !text.contains("expiresAt") && clean(f))
   var deniedRetain=false
   do{try f.app.nativeProtectedRestartStore.retain(owner:f.app.owner,intent:m.intent,rotationID:m.rotationID,source:m.source.tunnel,candidate:m.candidate.tunnel,sourceConfig:m.sourceConfig,candidateConfig:m.candidateConfig,selectedLocationID:m.selectedLocationID,targetLocationID:m.targetLocationID,requiresStageConsent:true)}catch{deniedRetain=true}
   a("retired-original-material-cannot-be-recreated-or-renewed",try deniedRetain && clean(f) && Data(contentsOf:wal)==bytes)
   let t=m.intent,newIntent=NativeProtectedReplacementCoordinator.RestartIntent(transactionID:UUID().uuidString,sourceSHA256:t.sourceSHA256,candidateSHA256:t.candidateSHA256,ownerTokenSHA256:t.ownerTokenSHA256,scopeFingerprint:t.scopeFingerprint,processInstanceID:t.processInstanceID,generation:t.generation)
   try f.app.nativeProtectedRestartStore.retain(owner:f.app.owner,intent:newIntent,rotationID:m.rotationID,source:m.source.tunnel,candidate:m.candidate.tunnel,sourceConfig:m.sourceConfig,candidateConfig:m.candidateConfig,selectedLocationID:m.selectedLocationID,targetLocationID:m.targetLocationID,requiresStageConsent:true)
   let newMaterial=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   a("different-explicit-nonce-can-retain-with-old-proof-inert",try newMaterial.intent==newIntent && Data(contentsOf:wal)==bytes && inert(f))
   try f.app.nativeProtectedRestartStore.retainStageConsent(owner:f.app.owner,material:newMaterial)
   _=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:newMaterial,now:UInt64(Date().timeIntervalSince1970),generate:{String(repeating:"d",count:64)})
   a("different-nonce-purpose-custody-never-admits-or-erases-old-proof",try f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:newMaterial)?.cancelled==false && Data(contentsOf:wal)==bytes && inert(f))
  }catch{a("terminal-canonical-bounded-metadata-has-no-secret-or-TTL",false);a("retired-original-material-cannot-be-recreated-or-renewed",false);a("different-explicit-nonce-can-retain-with-old-proof-inert",false);a("different-nonce-purpose-custody-never-admits-or-erases-old-proof",false)}
  do {
   let f=try await fresh("legacy-cancelled-marker"),m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!,s=try f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:m)!,cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)!
   // Represents prior C38 private ACK custody after capability cleanup. It is
   // fixture metadata, not a claimed live root cancellation or admission.
   try f.app.nativeProtectedRestartStore.markStageCancelled(owner:f.app.owner,material:m,expected:s)
   try f.app.nativeProtectedRestartStore.removeCapability(owner:f.app.owner,expected:cap)
   let before=f.helper.client.calls.count;try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   let wal=try f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)!
   a("legacy-cancelled-marker-with-material-migrates-no-new-RPC",try clean(f) && wal.capabilitySHA256==nil && f.helper.client.calls.count==before)
   reopen(f);try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("legacy-migration-terminal-repeat-no-absence-authority",try clean(f) && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)==wal && f.helper.client.calls.count==before)
  }catch{a("legacy-cancelled-marker-with-material-migrates-no-new-RPC",false);a("legacy-migration-terminal-repeat-no-absence-authority",false)}
  do {
   let f=try await fresh("directory-swap"),dir=f.root.appendingPathComponent("push-psk-events"),backup=f.root.appendingPathComponent("held-inbox"),outside=f.root.appendingPathComponent("external-directory")
   try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
   let marker=outside.appendingPathComponent("untouched");try Data("untouched".utf8).write(to:marker)
   var swapped=false
   f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{step in if step=="after-purpose-remove" && !swapped{swapped=true;try FileManager.default.moveItem(at:dir,to:backup);try FileManager.default.createSymbolicLink(at:dir,withDestinationURL:outside)}})
   let bad=await denied(f)
   a("directory-swap-after-first-delete-refused-no-redirection",try bad && swapped && Data(contentsOf:marker)==Data("untouched".utf8) && FileManager.default.contentsOfDirectory(at:outside,includingPropertiesForKeys:nil).count==1)
   try FileManager.default.removeItem(at:dir);try FileManager.default.moveItem(at:backup,to:dir);reopen(f)
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("original-owned-directory-restored-exact-retirement-retry",try clean(f) && f.helper.client.cancels==1 && Data(contentsOf:marker)==Data("untouched".utf8))
  }catch{a("directory-swap-after-first-delete-refused-no-redirection",false);a("original-owned-directory-restored-exact-retirement-retry",false)}
  do {
   let f=try await fresh("absence-is-not-proof"),nonce=try path(f,"promotion-"),nb=try Data(contentsOf:nonce)
   for prefix in ["restart-capability-","stage-consent-","restart-material-"]{try FileManager.default.removeItem(at:try path(f,prefix))}
   let before=f.helper.client.calls.count,bad=await denied(f)
   a("all-private-inputs-absent-without-WAL-no-cleanup-or-RPC",try bad && Data(contentsOf:nonce)==nb && f.helper.client.calls.count==before && f.app.nativeProtectedRestartStore.stageCancellationRetirement(owner:f.app.owner)==nil && inert(f))
  }catch{a("all-private-inputs-absent-without-WAL-no-cleanup-or-RPC",false)}
  print("stage_cancel_retirement_matrix cases=\(cases) failures=\(failures) live_network_commands=0 root_port=inert OS_crash_acceptance=not_claimed")
  exit(failures==0 ? 0:1)
 }
}
'''
HARNESS = H + "\n" + MAIN
if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="stage-cancel-retirement-", dir=Path(os.environ.get("TMPDIR", "/private/tmp")).resolve()) as raw:
        d = Path(raw)
        (d / "main.swift").write_text(HARNESS)
        data = d / "app-data"
        data.mkdir(mode=0o700)
        files = [S / "Models/VEXModels.swift"] + [P / n for n in [
            "VPNProfileCache.swift", "NativeAwgBoolean.swift", "NativePSKIdentifier.swift", "NativePushPSKEventQueue.swift", "NativePushSecureFileStore.swift",
            "NativePSKStagedProfileStore.swift", "NativePSKRotationValidation.swift", "NativeVPNProfileAuthorizationVerifier.swift", "NativeAdmittedProfileStore.swift",
            "NativeProtectedReplacementCoordinator.swift", "NativeProtectedPromotionStore.swift", "NativeProtectedRestartStore.swift", "NativeProtectedRestartCoordinator.swift"]]
        built = subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, files), str(d / "main.swift"), "-o", str(d / "probe")], capture_output=True, timeout=180)
        sys.stdout.buffer.write(built.stdout)
        sys.stderr.buffer.write(built.stderr)
        if built.returncode:
            raise SystemExit(built.returncode)
        result = subprocess.run(["rtk", "proxy", str(d / "probe"), str(data)], capture_output=True, timeout=180)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        names = [line.split(" ")[1].split("=")[0] for line in result.stdout.decode().splitlines() if line.startswith("stage_cancel_retirement ")]
        if len(names) != 81 or len(set(names)) != 81 or b"stage_cancel_retirement_matrix cases=81 " not in result.stdout:
            raise SystemExit(1)
        raise SystemExit(result.returncode)
