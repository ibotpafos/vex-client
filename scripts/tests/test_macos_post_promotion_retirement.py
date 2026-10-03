#!/usr/bin/env python3
"""Actual App/helper/coordinators and descriptor-owned terminal private IO.

Only deterministic inert authenticated root ports. Real owned-file faults and
fresh store instances are NOT OS crash/console-UID/installed/network acceptance.
"""
from pathlib import Path
import os, runpy, subprocess, sys, tempfile
ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac';P=S/'Services'
if 'struct PromotionRetirement' not in (P/'NativeProtectedRestartStore.swift').read_text():
    print('post_promotion_retirement contract=ABSENT (one diagnostic; terminal private retirement missing; runtime branches NOT executed)')
    print('post_promotion_retirement_matrix cases=1 failures=1 live_network_commands=0')
    raise SystemExit(1)
v=runpy.run_path(str(Path(__file__).with_name('test_macos_pre_stage_client_consent.py')),run_name='promotion_fixture')
M=v['H'].replace('let nativeProtectedRestartStore:','var nativeProtectedRestartStore:')
jpath=Path(__file__).with_name('test_macos_client_journal_continuation.py')
j={'__name__':'retirement_journal_fixture','__file__':str(jpath)}
exec(compile(jpath.read_text().split('with tempfile.TemporaryDirectory(',1)[0],str(jpath),'exec'),j)
J=j['H'].split('@main struct Main {',1)[0].replace('let nativeProtectedRestartStore:','var nativeProtectedRestartStore:')
for kind,h in [('journal',J),('main',M)]:
    h=h.replace('var calls:[String]=[],mode="', 'var retirementFault="",normalHash="",normalOwner=""\n var calls:[String]=[],mode="',1)
    at=h.index('  calls.append(command);',h.index('@MainActor final class Client {'))
    h=h[:at]+'''  if command.hasPrefix("protected-receipt") || command == "protected-snapshot" {
   if retirementFault == "account-after-proof" {app.session!.user.id="other"}
   if retirementFault == "token-after-proof" {app.session!.accessToken="other"}
   if retirementFault == "install-after-proof" {app.nativePushIdentityStore.value="other"}
   if retirementFault == "helper-after-proof" {app.nativePSKHelper!.canUseExistingValidatedHelper=false}
   if retirementFault == "transport" {calls.append(command);throw HelperError.protocolViolation("fixture-raw-must-not-surface")}
  }
'''+h[at:]
    h=h.replace('func send(_ command:String,timeoutSeconds:Int)async throws->String {','func rawSend(_ command:String,timeoutSeconds:Int)async throws->String {',1)
    at=h.index(' func rawSend(',h.index('@MainActor final class Client {'))
    h=h[:at]+r''' func send(_ command:String,timeoutSeconds:Int)async throws->String {
  var text=try await rawSend(command,timeoutSeconds:timeoutSeconds)
  guard command.hasPrefix("protected-receipt") || command == "protected-snapshot",!retirementFault.isEmpty else{return text}
  if retirementFault=="unknown"{text=String(text.dropLast())+" unknown=1\n"}
  if retirementFault=="duplicate"{text=String(text.dropLast())+" "+text.split(separator:" ").first{$0.contains("=")}!+"\n"}
  if retirementFault=="CRLF"{text=String(text.dropLast())+"\r\n"}
  if retirementFault=="multiline"{text+=text}
  if retirementFault=="empty-token"{text=text.replacingOccurrences(of:" ",with:"  ")}
  if retirementFault=="oversize"{text=String(repeating:"x",count:4097)+"\n"}
  if retirementFault=="wrong-id"{text=text.replacingOccurrences(of:app.material.intent.transactionID,with:UUID().uuidString)}
  if retirementFault=="wrong-source"{text=text.replacingOccurrences(of:app.material.intent.sourceSHA256,with:String(repeating:"d",count:64))}
  if retirementFault=="wrong-candidate"{text=text.replacingOccurrences(of:app.material.intent.candidateSHA256,with:String(repeating:"d",count:64))}
  if retirementFault=="wrong-owner"{text=text.replacingOccurrences(of:"owner_token_sha256=",with:"owner_token_sha256="+String(repeating:"d",count:64))}
  if retirementFault=="zero-HS"{text=text.replacingOccurrences(of:"latest_handshake=\(app.handshake)",with:"latest_handshake=0")}
  if retirementFault=="different-HS"{text=text.replacingOccurrences(of:"latest_handshake=\(app.handshake)",with:"latest_handshake=\(app.handshake-1)")}
  if retirementFault=="future-HS"{text=text.replacingOccurrences(of:"latest_handshake=\(app.handshake)",with:"latest_handshake=9999999999")}
  if retirementFault=="bad-protocol"{text=text.replacingOccurrences(of:"_protocol=1",with:"_protocol=2")}
  return text
 }
'''+h[at:]
    if kind=='journal':
        h=h.replace('   snapshots+=1;try boundary("snapshot")',r'''   snapshots+=1;try boundary("snapshot")
   if !normalHash.isEmpty{return "protected_protocol=1 recovery_pending=false source_sha256=\(normalHash) owner_token_sha256=\(normalOwner) commit_receipt_protocol=1\n"}''',1)
        h=h.replace('  return client.newOwner\n }', '  client.normalHash=hash;client.normalOwner=client.newOwner\n  return client.newOwner\n }',1)
        J=h
    else:M=h
COMMON=r'''
@MainActor func recordPath(_ f:Fixture,_ prefix:String)throws->URL {
 guard let u=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(prefix) && (prefix != "promotion-" || !$0.lastPathComponent.hasPrefix("promotion-retirement-")) && (prefix != "staged-" || !$0.lastPathComponent.hasPrefix("staged-index-"))})else{throw ProbeError.injected};return u
}
@MainActor func privateHashes(_ f:Fixture)throws->[String:String] {
 let dir=f.root.appendingPathComponent("push-psk-events");var result=[String:String]()
 for u in try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil) where u.pathExtension=="json" {
  result[u.lastPathComponent]=SHA256.hash(data:try Data(contentsOf:u)).map{String(format:"%02x",$0)}.joined()
 }
 return result
}
@MainActor func writeObject(_ object:[String:Any],_ u:URL)throws {
 var d=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);d.append(10);try d.write(to:u);precondition(chmod(u.path,0o600)==0)
}
@MainActor func reopen(_ f:Fixture){f.app.nativeProtectedRestartStore = .init(appDataURL:f.root)}
@MainActor func retryDenied(_ f:Fixture,_ action:AppState.NativeProtectedRestartAction = .cancel)async->Bool {
 do{try await f.app.applyNativeProtectedRestart(action,helper:f.helper);return false}catch{return true}
}
@MainActor func clean(_ f:Fixture)throws->Bool {
 try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil
  && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
  && !f.app.nativeProtectedRestartStore.hasPrivateCustody(owner:f.app.owner)
  && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)?.phase=="retired"
}
'''
JMAIN=r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0,names=Set<String>()
  func a(_ name:String,_ ok:Bool){cases+=1;let unique=names.insert(name).inserted;if !ok || !unique{failures+=1};print("post_promotion_retirement \(name)=\(ok && unique ? "PASS":"FAIL")")}
  func run(_ name:String,_ op:()async throws->Bool)async {do{a(name,try await op())}catch{print("post_promotion_fixture_error name=\(name) type=\(String(describing:type(of:error))) code=\((error as NSError).code)");a(name,false)}}
  func route(_ value:String)->AppState.NativeProtectedRestartAction {value=="recover" ? .recover:value=="resume" ? .resumeCandidate:.restoreSource}
  func fresh(_ label:String,_ value:String)throws->Fixture {let f=try Fixture(label);if value=="recover"{f.helper.client.mode="receipt-ACK"}else{try f.journalize()};return f}
  func stopped(_ label:String,_ value:String,_ step:String="promotion-before-nonce-remove")async throws->Fixture {
   let f=try fresh(label,value);var fired=false
   f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step{fired=true;throw ProbeError.injected}})
   do{try await f.app.applyNativeProtectedRestart(route(value),helper:f.helper)}catch{}
   guard fired,try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner) != nil else{throw ProbeError.injected};reopen(f);return f
  }
  let steps=["promotion-before-WAL-write","promotion-after-WAL-write","promotion-after-WAL-readback","promotion-before-nonce-remove","promotion-after-nonce-remove","promotion-before-capability-remove","promotion-after-capability-remove","promotion-before-purpose-remove","promotion-after-purpose-remove","promotion-before-material-remove","promotion-after-material-remove","promotion-before-stage-remove","promotion-after-stage-remove","promotion-before-retired-write","promotion-after-retired-write","promotion-after-retired-readback"]
  for value in ["recover","resume","source"] {
   for step in steps where value != "source" || !step.contains("stage-remove") {
    await run(value+"-"+step+"-observed-IO-and-fresh-store-private-only-retry"){
     let f=try fresh(value+step,value);var fired=false
     f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step && !fired{fired=true;throw ProbeError.injected}})
     do{try await f.app.applyNativeProtectedRestart(route(value),helper:f.helper)}catch{}
     let wal=try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)
     guard fired,(wal != nil)==(step != "promotion-before-WAL-write") else{return false}
     let calls=f.helper.client.calls.count,adopts=f.helper.client.adoptions,commits=f.helper.client.commits,recovers=f.helper.client.recovers,cache=f.app.profileService.cache.saves,admissions=f.helper.client.admissionProofs
     reopen(f);try await f.app.applyNativeProtectedRestart(wal == nil ? route(value):.cancel,helper:f.helper)
     let tail=Array(f.helper.client.calls.dropFirst(calls)),r=try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)!
     let safe=tail.allSatisfy{$0=="protected-snapshot" || $0.hasPrefix("protected-receipt ")}
     let exact = wal==nil || (tail.count==2 && f.app.profileService.cache.saves==cache)
     var generations=0,blocked=false
     do{_=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:f.app.material,now:UInt64(Date().timeIntervalSince1970)+121,generate:{generations+=1;return String(repeating:"1",count:64)})}catch{blocked=true}
     let fenced = value=="source" ? (try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner) != nil && f.noAdmission() && f.app.activeTunnel==nil):(try f.app.nativePSKStageStore.retirementAbsent(owner:f.app.owner,managedDeviceID:r.managedDeviceID,rotationID:r.rotationID))
     return try clean(f) && safe && exact && f.helper.client.adoptions==adopts && f.helper.client.commits==commits && f.helper.client.recovers==recovers && f.helper.client.admissionProofs==admissions && generations==0 && blocked && fenced && VPNProfileService.dnsCalls==0
    }
   }
  }
  for value in ["recover","source"] {
   let faults=value=="recover" ? ["unknown","duplicate","CRLF","multiline","empty-token","oversize","wrong-id","wrong-source","wrong-candidate","wrong-owner","zero-HS","different-HS","future-HS","bad-protocol","transport"]:["unknown","duplicate","CRLF","multiline","empty-token","oversize","wrong-source","wrong-owner","bad-protocol","transport"]
   for fault in faults {
    await run(value+"-terminal-proof-"+fault+"-no-private-delete"){
     let f=try await stopped(value+fault,value,value=="recover" ? "promotion-before-stage-remove":"promotion-before-material-remove")
     let before=try privateHashes(f),cache=f.app.profileService.cache.saves,adopts=f.helper.client.adoptions,commits=f.helper.client.commits,recovers=f.helper.client.recovers
     f.helper.client.retirementFault=fault;let denied=await retryDenied(f)
     return try denied && before==privateHashes(f) && f.app.profileService.cache.saves==cache && f.helper.client.adoptions==adopts && f.helper.client.commits==commits && f.helper.client.recovers==recovers
    }
   }
  }
  for change in ["account-after-proof","token-after-proof","install-after-proof","helper-after-proof"] {
   await run("current-"+change+"-vetoes-cleanup-after-await"){
    let f=try await stopped(change,"recover"),before=try privateHashes(f);f.helper.client.retirementFault=change
    let bad=await retryDenied(f);return try bad && before==privateHashes(f)
   }
  }
  for field in ["schema","namespace","ownerFingerprint","materialSHA256","nonceSHA256","kind","phase","unknown","oversize","receipt-HS"] {
   await run("strict-WAL-"+field+"-refused-no-delete"){
    let f=try await stopped(field,"recover"),url=try recordPath(f,"promotion-retirement-")
    var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    if field=="schema"{o[field]=2}else if ["materialSHA256","nonceSHA256","ownerFingerprint"].contains(field){o[field]=String(repeating:"0",count:64)}else if field=="receipt-HS"{var r=o["receipt"] as! [String:Any];r["latestHandshake"]=f.app.handshake-1;o["receipt"]=r}else{o[field]=field=="oversize" ? String(repeating:"x",count:16385):"invalid"}
    try writeObject(o,url);let before=try privateHashes(f),bad=await retryDenied(f)
    return try bad && before==privateHashes(f) && f.helper.client.adoptions==1 && f.app.profileService.cache.saves==1
   }
  }
  for mode in ["mode","symlink","hardlink","directory"] {
   await run("owned-WAL-"+mode+"-refused-outside-unchanged"){
    let f=try await stopped(mode,"recover"),u=try recordPath(f,"promotion-retirement-"),outside=f.root.appendingPathComponent("outside"),nonce=try recordPath(f,"promotion-")
    let nb=try Data(contentsOf:nonce);try Data("unchanged".utf8).write(to:outside)
    if mode=="mode"{precondition(chmod(u.path,0o644)==0)}
    if mode=="symlink"{try FileManager.default.removeItem(at:u);try FileManager.default.createSymbolicLink(at:u,withDestinationURL:outside)}
    if mode=="hardlink"{try FileManager.default.linkItem(at:u,to:outside.appendingPathExtension("link"))}
    if mode=="directory"{try FileManager.default.removeItem(at:u);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false)}
    let bad=await retryDenied(f);return try bad && Data(contentsOf:outside)==Data("unchanged".utf8) && Data(contentsOf:nonce)==nb
   }
  }
  for item in ["nonce","material","capability","stage","source-fence"] {
   await run("changed-"+item+"-preserved-no-other-delete"){
    let value=item=="source-fence" ? "source":"recover",f=try await stopped(item,value)
    let prefix=item=="nonce" ? "promotion-":item=="material" ? "restart-material-":item=="capability" ? "restart-capability-":item=="stage" ? "staged-":"source-restoration-"
    let url=try recordPath(f,prefix);var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    if item=="nonce"{var t=o["transaction"] as! [String:Any];t["stageConsentPending"]=true;o["transaction"]=t}
    else if item=="capability"{o["value"]=String(repeating:"d",count:64)}
    else if item=="stage"{o["stagedAt"]=(o["stagedAt"] as! Double)+1}
    else if item=="material"{o["selectedLocationID"]="us"}else{o["materialSHA256"]=String(repeating:"d",count:64)}
    try writeObject(o,url);let before=try privateHashes(f),bad=await retryDenied(f);return try bad && before==privateHashes(f)
   }
  }
  for value in ["recover","source"] {
   await run(value+"-secret-purge-retains-terminal-WAL-no-metadata-admission"){
    let f=try await stopped(value+"purge",value)
    try f.app.nativeProtectedRestartStore.purge(owner:f.app.owner);f.app.nativeAdmittedProfiles.clear();f.app.activeTunnel=nil
    let fence=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner),cache=f.app.profileService.cache.saves
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    let noAdmission=(try? f.app.nativeAdmittedProfiles.source(for:f.app.material.candidate.tunnel,scope:f.app.nativeAdmittedProfileScope(for:f.app.material.candidate.tunnel),helper:f.helper))==nil
    return try clean(f) && noAdmission && f.app.activeTunnel==nil && f.app.profileService.cache.saves==cache && (value != "source" || fence != nil)
   }
  }
  await run("terminal-WAL-denies-authorize-and-direct-journal-before-RPC"){
   let f=try await stopped("no-restart","resume"),n=f.helper.client.calls.count
   let original=f.app.material!,p=try f.app.nativePSKPromotionPersistence(previous:f.source,next:original.candidate.tunnel,owner:f.app.owner,helper:f.helper,generation:11,sessionGeneration:4,token:"fixture-token")
   let t=try NativeProtectedReplacementCoordinator.restartIntent(p.load()!)
   let blocked=await retryDenied(f,.authorize);var resume=false,restore=false
   do{_=try await f.helper.resumeProtectedJournal(t,persistence:p,dependencies:f.dependencies())}catch{resume=true}
   do{try await f.helper.restoreProtectedJournal(t,persistence:p,dependencies:f.dependencies())}catch{restore=true}
   return blocked && resume && restore && f.helper.client.calls.count==n
  }
  await run("retired-WAL-does-not-shadow-unrelated-fresh-private-custody"){
   let f=try fresh("new-tuple","recover");try await f.app.applyNativeProtectedRestart(.recover,helper:f.helper)
   let old=f.app.material!,t=old.intent
   let next=NativeProtectedReplacementCoordinator.RestartIntent(transactionID:UUID().uuidString,sourceSHA256:t.sourceSHA256,candidateSHA256:t.candidateSHA256,ownerTokenSHA256:t.ownerTokenSHA256,scopeFingerprint:t.scopeFingerprint,processInstanceID:NativeProtectedReplacementCoordinator.processInstanceID,generation:12)
   try f.app.nativeProtectedRestartStore.retain(owner:f.app.owner,intent:next,rotationID:old.rotationID,source:old.source.tunnel,candidate:old.candidate.tunnel,sourceConfig:old.sourceConfig,candidateConfig:old.candidateConfig,selectedLocationID:old.selectedLocationID,targetLocationID:old.targetLocationID)
   return try !f.app.nativeProtectedRestartStore.promotionRetirementPending(owner:f.app.owner) && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)?.intent==next
  }
  for step in ["promotion-before-normal-proof-write","promotion-after-normal-proof-write","promotion-after-normal-proof-readback","promotion-before-nonce-remove","promotion-after-material-remove"] {
   await run("new-normal-admission-"+step+"-private-retry-fence-retained"){
    let f=try await stopped(step,"source"),fence=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)
    var fired=false;f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step{fired=true;throw ProbeError.injected}})
    f.app.desiredVpnState = .connected;f.app.nativeProtectedRestorationAdmissionGeneration=f.app.vpnOperationGeneration
    await f.app.rememberNativeAdmittedProfile(f.app.material.candidate.tunnel,canonicalConfig:f.app.material.candidateConfig,helper:f.helper,generation:f.app.vpnOperationGeneration,sessionGeneration:4,accessToken:"fixture-token",accountID:"fixture-account")
    guard fired,try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==fence else{return false};reopen(f)
    if step=="promotion-before-normal-proof-write" {
     let before=try privateHashes(f);guard await retryDenied(f),try before==privateHashes(f) else{return false}
     await f.app.rememberNativeAdmittedProfile(f.app.material.candidate.tunnel,canonicalConfig:f.app.material.candidateConfig,helper:f.helper,generation:f.app.vpnOperationGeneration,sessionGeneration:4,accessToken:"fixture-token",accountID:"fixture-account")
     return try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil
    }
    let calls=f.helper.client.calls.count,admissions=f.helper.client.admissionProofs
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    return try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==fence && f.helper.client.calls.count==calls+2 && f.helper.client.admissionProofs==admissions && f.helper.client.recovers==1
   }
  }
  await run("pre-WAL-legacy-orphan-no-authority-from-missing-nonce"){
   let f=try fresh("orphan","source");f.helper.client.mode="recover-lost"
   do{try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)}catch{}
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   let before=try privateHashes(f),n=f.helper.client.calls.count,bad=await retryDenied(f,.restoreSource)
   f.app.desiredVpnState = .connected;f.app.nativeProtectedRestorationAdmissionGeneration=f.app.vpnOperationGeneration
   await f.app.rememberNativeAdmittedProfile(f.app.material.candidate.tunnel,canonicalConfig:f.app.material.candidateConfig,helper:f.helper,generation:f.app.vpnOperationGeneration,sessionGeneration:4,accessToken:"fixture-token",accountID:"fixture-account")
   return try bad && before==privateHashes(f) && f.helper.client.calls.count==n && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner) != nil
  }
  print("post_promotion_journal_matrix cases=\(cases) failures=\(failures) live_network_commands=0");exit(failures==0 ? 0:1)
 }
}
'''
MMAIN=r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0,names=Set<String>()
  func a(_ name:String,_ ok:Bool){cases+=1;let unique=names.insert(name).inserted;if !ok || !unique{failures+=1};print("post_promotion_retirement \(name)=\(ok && unique ? "PASS":"FAIL")")}
  func run(_ name:String,_ op:()async throws->Bool)async {do{a(name,try await op())}catch{print("post_promotion_fixture_error name=\(name) type=\(String(describing:type(of:error))) code=\((error as NSError).code)");a(name,false)}}
  func fresh(_ label:String)throws->Fixture {
   let f=try Fixture(label,oldProcess:false)
   try f.app.nativeProtectedRestartStore.removeMaterial(owner:f.app.owner,expected:f.app.material)
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.activeTunnel=f.source;f.app.nativePSKPreparedTunnel=f.source;f.app.desiredVpnState = .connected
   f.app.nativeProtectedStageConsentEnabled=true;f.app.vpnOperationGeneration=11
   f.app.profileService.canonicalCandidate=f.app.material.candidateConfig
   _=try f.app.nativeAdmittedProfiles.record(tunnel:f.source,canonicalConfig:f.app.material.sourceConfig,ownerTokenSHA256:f.app.material.intent.ownerTokenSHA256,scope:try f.app.nativeAdmittedProfileScope(for:f.source),helper:f.helper);return f
  }
  func stopped(_ label:String,_ step:String)async throws->Fixture {
   let f=try fresh(label);var fired=false
   f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step{fired=true;throw ProbeError.injected}})
   do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)}catch{}
   guard fired,try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner) != nil else{throw ProbeError.injected};reopen(f);return f
  }
  let steps=["promotion-after-WAL-write","promotion-after-WAL-readback","promotion-before-nonce-remove","promotion-after-nonce-remove","promotion-before-capability-remove","promotion-after-capability-remove","promotion-before-purpose-remove","promotion-after-purpose-remove","promotion-before-material-remove","promotion-after-material-remove","promotion-before-stage-remove","promotion-after-stage-remove","promotion-before-retired-write","promotion-after-retired-write","promotion-after-retired-readback"]
  for step in steps {
   await run("main-opt-in-"+step+"-explicit-private-retry-no-cutover-cache"){
    let f=try await stopped(step,step),c=f.helper.client,tailStart=c.calls.count
    guard f.app.activeTunnel?.profileVersion==2,f.app.profileService.cache.saves==1 else{return false}
    let before=try privateHashes(f);var blocked=false
    do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)}catch{blocked=true}
    guard blocked,try before==privateHashes(f),c.calls.count==tailStart else{return false}
    f.app.entitlement!.hasPaidAccess=false;f.app.nativeRemotePushEnabled=false;f.app.nativePushConsentMatchesSession=false;f.app.profileService.keyStore.pair=nil
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper);let tail=Array(c.calls.dropFirst(tailStart))
    return try clean(f) && tail.count==2 && tail.allSatisfy{$0.hasPrefix("protected-receipt ")} && c.auths==1 && c.replacements==1 && c.commits==1 && c.cancels==0 && c.recoveries==0 && f.app.profileService.cache.saves==1 && f.app.activeTunnel?.profileVersion==2 && f.app.nativePSKCommittedPromotion==nil && f.app.profileService.prepares==1 && VPNProfileService.dnsCalls==0
   }
  }
  for step in ["stage-before-file-remove","stage-after-file-remove","stage-before-index-write","stage-after-index-write","stage-after-index-readback"] {
   await run("main-owned-stage-"+step+"-exact-index-retry-no-root-mutation"){
    let f=try fresh(step);var fired=false
    f.app.nativePSKStageStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step{fired=true;throw ProbeError.injected}})
    do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)}catch{}
    guard fired,try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)?.phase=="retiring" else{return false}
    let calls=f.helper.client.calls.count
    f.app.nativePSKStageStore = .init(appDataURL:f.root);reopen(f)
    try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    return try clean(f) && f.helper.client.calls.count==calls+2 && f.helper.client.replacements==1 && f.helper.client.commits==1 && f.app.profileService.cache.saves==1 && f.app.nativePSKStageStore.retirementAbsent(owner:f.app.owner,managedDeviceID:f.source.device.id,rotationID:f.envelope.rotationID)
   }
  }
  for item in ["purpose","nonce-consumed","nonce-rebound","stage-index-corrupt","stage-index-unknown"] {
   await run("main-remaining-"+item+"-CAS-preserves-custody"){
    let f=try await stopped(item,"promotion-before-nonce-remove")
    let u=try recordPath(f,item=="purpose" ? "stage-consent-":item.hasPrefix("stage-index-") ? "staged-index-":"promotion-")
    var o=try JSONSerialization.jsonObject(with:Data(contentsOf:u)) as! [String:Any]
    if item=="purpose"{o["cancelled"]=true}else if item=="stage-index-corrupt"{o["schema"]=99}else if item=="stage-index-unknown"{o["unknown"]=true}else{var t=o["transaction"] as! [String:Any];if item=="nonce-consumed"{t["stageConsentPending"]=true}else{t["owner"]=String(repeating:"d",count:64)};o["transaction"]=t}
    try writeObject(o,u);let before=try privateHashes(f),bad=await retryDenied(f)
    return try bad && before==privateHashes(f) && f.helper.client.replacements==1 && f.app.profileService.cache.saves==1
   }
  }
  await run("terminal-WAL-bounded-metadata-no-secret-no-TTL"){
   let f=try await stopped("metadata","promotion-before-nonce-remove"),u=try recordPath(f,"promotion-retirement-")
   let d=try Data(contentsOf:u),s=String(decoding:d,as:UTF8.self),o=try JSONSerialization.jsonObject(with:d) as! [String:Any]
   let cap=try Data(contentsOf:recordPath(f,"restart-capability-")),raw=(try JSONSerialization.jsonObject(with:cap) as! [String:Any])["value"] as! String
   let forbidden=[raw,f.app.material.sourceConfig,f.app.material.candidateConfig,f.app.owner.accountID,f.app.owner.installationID,"expiresAt","issuedAt","preshared_key"]
   let mode=(try FileManager.default.attributesOfItem(atPath:u.path)[.posixPermissions] as! NSNumber).intValue
   return d.count<16384 && mode==0o600 && o["kind"] as? String == "candidate" && !forbidden.contains{s.contains($0)}
  }
  print("post_promotion_main_matrix cases=\(cases) failures=\(failures) live_network_commands=0");exit(failures==0 ? 0:1)
 }
}
'''
FILES=[S/'Models/VEXModels.swift']+[P/n for n in ['VPNProfileCache.swift','NativeAwgBoolean.swift','NativePSKIdentifier.swift','NativePushPSKEventQueue.swift','NativePushSecureFileStore.swift','NativePSKStagedProfileStore.swift','NativePSKRotationValidation.swift','NativeVPNProfileAuthorizationVerifier.swift','NativeAdmittedProfileStore.swift','NativeProtectedReplacementCoordinator.swift','NativeProtectedPromotionStore.swift','NativeProtectedRestartStore.swift','NativeProtectedRestartCoordinator.swift']]
if 'beginLegacyPromotionRetirement(' in (P/'NativeProtectedRestartStore.swift').read_text():
    # Preserve the no-absence-authority assertion BEFORE admission. C41 changes
    # only the explicit NEW normal admission result, now with two root proofs.
    before_admission='let before=try privateHashes(f),n=f.helper.client.calls.count,bad=await retryDenied(f,.restoreSource)'
    assert JMAIN.count(before_admission)==1
    JMAIN=JMAIN.replace(before_admission,before_admission+'\n   guard bad,try before==privateHashes(f),f.helper.client.calls.count==n else{return false}')
    JMAIN=JMAIN.replace('return try bad && before==privateHashes(f) && f.helper.client.calls.count==n && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner) != nil',
        'return try bad && clean(f) && f.helper.client.calls.count==n+2 && f.helper.client.admissionProofs==1 && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil && f.helper.client.recovers==1 && f.app.profileService.cache.saves==0')
expected=[('journal',J,JMAIN,104),('main',M,MMAIN,26)]
if __name__=='__main__':
    total=failed=0;seen=[]
    with tempfile.TemporaryDirectory(prefix='post-promotion-',dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
        d=Path(raw)
        for label,h,main,count in expected:
            source=d/(label+'.swift');source.write_text(h+'\n'+COMMON+'\n'+main)
            r=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,FILES),str(source),'-o',str(d/label)],capture_output=True)
            sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
            if r.returncode:raise SystemExit(r.returncode)
            data=d/(label+'-data');data.mkdir(mode=0o700)
            r=subprocess.run(['rtk','proxy',str(d/label),str(data)],capture_output=True,timeout=120)
            sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
            names=[x.split(' ')[1].split('=')[0] for x in r.stdout.decode().splitlines() if x.startswith('post_promotion_retirement ')]
            errors=sum('=FAIL' in x for x in r.stdout.decode().splitlines() if x.startswith('post_promotion_retirement '))
            if len(names)!=count or len(set(names))!=count or r.returncode:failed+=max(1,errors)
            total+=len(names);seen+=names
    if len(seen)!=len(set(seen)):failed+=1
    app=(S/'Stores/VEXAppState.swift').read_text();ui=(S/'Views/VEXSettingsView.swift').read_text()
    wiring=all(x in ui for x in ['hasNativeProtectedPrivateRetirement','cleanupNativeProtectedPrivateData']) and ('TODO(post-promotion-legacy-orphan)' in app or ('reconcileLegacyProtectedPrivateRetirement' in app and 'TODO(post-promotion-legacy-platform-QA)' in app))
    print('post_promotion_retirement explicit-private-UI-and-honest-legacy-TODO='+('PASS' if wiring else 'FAIL'))
    total+=1;failed+=not wiring
    print(f'post_promotion_retirement_matrix cases={total} failures={failed} live_network_commands=0')
    raise SystemExit(0 if failed==0 else 1)
