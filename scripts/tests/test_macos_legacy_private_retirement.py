#!/usr/bin/env python3
"""Actual private IO, App/helper/coordinators; inert authenticated root replies.

No installed helper, ordinary connection, DNS/PF/tunnel or OS crash acceptance.
The admission mode separately tests the exact current root wire grammar and
the explicit previous six-field compatibility contract against real code.
"""
from pathlib import Path
import os, runpy, subprocess, sys, tempfile

ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac';P=S/'Services'
MODE=sys.argv[2] if len(sys.argv)>2 else 'legacy'

ADMISSION=r'''
import Foundation
@main struct Main {
 @MainActor static func main()async {
  let hash=String(repeating:"a",count:64),owner=String(repeating:"b",count:64),id="11111111-1111-4111-8111-111111111111"
  let wire="protected_protocol=1 recovery_pending=false source_sha256=\(hash) owner_token_sha256=\(owner) commit_receipt_protocol=1\n"
  var cases=0,failures=0
  func a(_ name:String,_ ok:Bool){cases+=1;failures+=ok ? 0:1;print("normal_admission_wire \(name)=\(ok ? "PASS":"FAIL")")}
  for format in [0,1,2] {
   let text=format==0 ? wire:String(wire.dropLast()).replacingOccurrences(of:format==2 ? " commit_receipt_protocol=1":"UNUSED",with:"")+" transaction_id=\(id)\n"
   let name=format==0 ? "current-root-five-fields-no-invented-transaction":format==1 ? "previous-six-fields-explicit-compatibility":"previous-five-fields-normal-admission-only-compatibility"
   do {
    var commands=[String]()
    let value=try await NativeProtectedReplacementCoordinator().verifyAdmittedSource(hash,isCurrent:{true},send:{cmd,_ in commands.append(cmd);return text})
    a(name,value==owner && commands==["protected-snapshot"])
   } catch {a(name,false)}
  }
  for format in [0,1,2] {
   for fault in ["unknown","duplicate","missing","CRLF","multiline","tab","double-space","leading-space","trailing-space","oversize","NUL","pending","protocol","receipt-protocol","wrong-source","wrong-owner","legacy-invalid-UUID"] {
   var text=format==0 ? wire:String(wire.dropLast()).replacingOccurrences(of:format==2 ? " commit_receipt_protocol=1":"UNUSED",with:"")+" transaction_id=\(id)\n"
   if fault=="unknown"{text=String(text.dropLast())+" unknown=1\n"}
   if fault=="duplicate"{text=String(text.dropLast())+" protected_protocol=1\n"}
   if fault=="missing"{text=text.replacingOccurrences(of:" owner_token_sha256=\(owner)",with:"")}
   if fault=="CRLF"{text=String(text.dropLast())+"\r\n"}
   if fault=="multiline"{text+=text}
   if fault=="tab"{text=text.replacingOccurrences(of:" ",with:"\t")}
   if fault=="double-space"{text=text.replacingOccurrences(of:" ",with:"  ")}
   if fault=="leading-space"{text=" "+text}
   if fault=="trailing-space"{text=String(text.dropLast())+" \n"}
   if fault=="oversize"{text=String(repeating:"x",count:4097)+"\n"}
   if fault=="NUL"{text=String(text.dropLast())+"\0\n"}
   if fault=="pending"{text=text.replacingOccurrences(of:"pending=false",with:"pending=true")}
   if fault=="protocol"{text=text.replacingOccurrences(of:"protected_protocol=1",with:"protected_protocol=2")}
   if fault=="receipt-protocol"{text=format==2 ? String(text.dropLast())+" commit_receipt_protocol=2\n":text.replacingOccurrences(of:"receipt_protocol=1",with:"receipt_protocol=2")}
   if fault=="wrong-source"{text=text.replacingOccurrences(of:hash,with:String(repeating:"c",count:64))}
   if fault=="wrong-owner"{text=text.replacingOccurrences(of:owner,with:"not-a-digest")}
   if fault=="legacy-invalid-UUID"{text=format != 0 ? text.replacingOccurrences(of:id,with:"not-a-UUID"):String(text.dropLast())+" transaction_id=not-a-UUID\n"}
   var denied=false
   do{_=try await NativeProtectedReplacementCoordinator().verifyAdmittedSource(hash,isCurrent:{true},send:{_,_ in text})}catch{denied=true}
   a("format\(format)-"+fault+"-closed-contract-denied",denied)
   }
  }
  for before in [true,false] {
   var current = !before,calls=0,denied=false
   do{_=try await NativeProtectedReplacementCoordinator().verifyAdmittedSource(hash,isCurrent:{current},send:{_,_ in calls+=1;current=false;return wire})}catch{denied=true}
   a(before ? "stale-before-no-RPC":"stale-after-await-no-admission",denied && calls==(before ? 0:1))
  }
  print("normal_admission_wire_matrix cases=\(cases) failures=\(failures) live_network_commands=0");exit(failures==0 ? 0:1)
 }
}
'''

def execute(files,harness,prefix,count):
    with tempfile.TemporaryDirectory(prefix=prefix+'-',dir=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()) as raw:
        d=Path(raw);main=d/'main.swift';main.write_text(harness);data=d/'data';data.mkdir(mode=0o700)
        r=subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,files),str(main),'-o',str(d/'probe')],capture_output=True)
        sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
        if r.returncode:raise SystemExit(r.returncode)
        r=subprocess.run(['rtk','proxy',str(d/'probe'),str(data)],capture_output=True,timeout=120)
        sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
        names=[x.split(' ')[1].split('=')[0] for x in r.stdout.decode().splitlines() if x.startswith(prefix+' ')]
        assert len(names)==count and len(set(names))==count, (prefix,len(names),count)
        raise SystemExit(r.returncode)

if MODE=='admission':
    execute([P/'NativeProtectedReplacementCoordinator.swift'],ADMISSION,'normal_admission_wire',56)
if MODE!='legacy':raise SystemExit('mode must be legacy or admission')
if 'beginLegacyPromotionRetirement(' not in (P/'NativeProtectedRestartStore.swift').read_text():
    print('legacy_private_retirement contract=ABSENT (one diagnostic; no-nonce legacy retirement missing; runtime branches NOT executed)')
    print('legacy_private_retirement_matrix cases=1 failures=1 live_network_commands=0')
    raise SystemExit(1)
v=runpy.run_path(str(Path(__file__).with_name('test_macos_post_promotion_retirement.py')),run_name='legacy_fixture')
H=v['J'];body=v['j']['body'];helper=(S/'VEXHelperClient.swift').read_text()
# Replace the old journal fixture's admission stub with the ACTUAL helper and
# coordinator proof. Root state is inert and already represents a NEW normal
# admission. No up/connect API exists in the fixture.
old=body(H,' func verifyAdmittedSource(')
H=H.replace(old,body(helper,'    func verifyAdmittedSource(').strip(),1)
H=H.replace('var retirementFault="",normalHash="",normalOwner=""',r'''var retirementFault="",normalHash="",normalOwner=""
 var normalReplies=0,legacyFault="",legacyFaultAt=2,noncePath:URL?,nonceBytes:Data?''',1)
old='if !normalHash.isEmpty{return "protected_protocol=1 recovery_pending=false source_sha256=\\(normalHash) owner_token_sha256=\\(normalOwner) commit_receipt_protocol=1\\n"}'
new=r'''if !normalHash.isEmpty {
    normalReplies+=1
    var text="protected_protocol=1 recovery_pending=false source_sha256=\(normalHash) owner_token_sha256=\(normalOwner) commit_receipt_protocol=1\n"
    if normalReplies==legacyFaultAt {
     if legacyFault=="account"{app.session!.user.id="other"}
     if legacyFault=="token"{app.session!.accessToken="other"}
     if legacyFault=="install"{app.nativePushIdentityStore.value="other"}
     if legacyFault=="helper"{app.nativePSKHelper!.canUseExistingValidatedHelper=false}
     if legacyFault=="generation"{app.vpnOperationGeneration+=1}
     if legacyFault=="desired"{app.desiredVpnState = .disconnected}
     if legacyFault=="key"{app.profileService.keyStore.pair=nil}
     if legacyFault=="key-epoch",let key=app.profileService.keyStore.pair{app.profileService.keyStore.pair = .init(privateKey:key.privateKey,publicKey:key.publicKey,keyEpoch:key.keyEpoch+1)}
     if legacyFault=="device"{app.accountDevices=[]}
     if legacyFault=="admission"{app.nativeAdmittedProfiles.clear()}
     if legacyFault=="nonce",let path=noncePath,let bytes=nonceBytes{try bytes.write(to:path);precondition(chmod(path.path,0o600)==0)}
     if legacyFault=="unknown"{text=String(text.dropLast())+" unknown=1\n"}
     if legacyFault=="duplicate"{text=String(text.dropLast())+" protected_protocol=1\n"}
     if legacyFault=="CRLF"{text=String(text.dropLast())+"\r\n"}
     if legacyFault=="multiline"{text+=text}
     if legacyFault=="double-space"{text=text.replacingOccurrences(of:" ",with:"  ")}
     if legacyFault=="oversize"{text=String(repeating:"x",count:4097)+"\n"}
     if legacyFault=="wrong-source"{text=text.replacingOccurrences(of:normalHash,with:String(repeating:"d",count:64))}
     if legacyFault=="wrong-owner"{text=text.replacingOccurrences(of:normalOwner,with:String(repeating:"d",count:64))}
     if legacyFault=="pending"{text=text.replacingOccurrences(of:"pending=false",with:"pending=true")}
     if legacyFault=="protocol"{text=text.replacingOccurrences(of:"protected_protocol=1",with:"protected_protocol=2")}
     if legacyFault=="receipt-protocol"{text=text.replacingOccurrences(of:"receipt_protocol=1",with:"receipt_protocol=2")}
     if legacyFault=="old-transaction"{text=String(text.dropLast())+" transaction_id=\(app.material.intent.transactionID)\n"}
     if legacyFault=="transport"{throw HelperError.protocolViolation("fixture-secret-not-for-UI")}
    }
    return text
   }'''
assert old in H
H=H.replace(old,new,1)

MAIN=r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0,names=Set<String>()
  func a(_ name:String,_ ok:Bool){cases+=1;let unique=names.insert(name).inserted;if !ok || !unique{failures+=1};print("legacy_private_retirement \(name)=\(ok && unique ? "PASS":"FAIL")")}
  func run(_ name:String,_ op:()async throws->Bool)async{do{a(name,try await op())}catch{print("legacy_fixture_error name=\(name) type=\(String(describing:type(of:error))) code=\((error as NSError).code)");a(name,false)}}
  func fresh(_ label:String)async throws->Fixture {
   let f=try Fixture(label);try f.journalize();f.helper.client.mode="recover-lost"
   do{try await f.app.applyNativeProtectedRestart(.restoreSource,helper:f.helper)}catch{}
   guard try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner) != nil,
         try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil else{throw ProbeError.injected}
   f.helper.client.noncePath=f.promotionURL();f.helper.client.nonceBytes=try Data(contentsOf:f.promotionURL())
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   return f
  }
  func admit(_ f:Fixture)async {
   f.app.desiredVpnState = .connected;f.app.nativeProtectedRestorationAdmissionGeneration=f.app.vpnOperationGeneration
   f.helper.client.normalHash=NativeProtectedReplacementCoordinator.digest(f.app.material.candidateConfig);f.helper.client.normalOwner=f.helper.client.newOwner
   await f.app.rememberNativeAdmittedProfile(f.app.material.candidate.tunnel,canonicalConfig:f.app.material.candidateConfig,helper:f.helper,generation:f.app.vpnOperationGeneration,sessionGeneration:4,accessToken:"fixture-token",accountID:"fixture-account")
  }
  func safeTail(_ f:Fixture,_ index:Int)->Bool{Array(f.helper.client.calls.dropFirst(index)).allSatisfy{$0=="protected-snapshot"}}
  func purpose(_ f:Fixture)throws {
   let m=f.app.material!,fp=NativeProtectedPromotionStore.fingerprint(["vex-protected-restart-v1",f.app.owner.accountID,f.app.owner.installationID])
   let value=NativeProtectedRestartStore.StageConsent(schema:1,namespace:"vex-protected-stage-consent-v1",ownerFingerprint:fp,intent:m.intent,materialSHA256:try f.app.nativeProtectedRestartStore.materialDigest(m),cancelled:false)
   let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];var data=try encoder.encode(value);data.append(10)
   try NativePushSecureFileStore(rootURL:f.root,maxBytes:16384).write(data,name:"stage-consent-"+fp+".json")
  }
  await run("new-normal-admission-actual-helper-three-read-only-proofs-no-invented-nonce") {
   let f=try await fresh("success"),n=f.helper.client.calls.count;await admit(f)
   let r=try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)!
   return try clean(f) && r.kind=="normal-admission-legacy-no-nonce" && r.nonceSHA256==nil && r.terminalIntent != r.materialIntent && r.receipt==nil && r.admittedProfileSHA256==f.helper.client.normalHash && r.sourceFenceSHA256 != nil && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil && f.helper.client.normalReplies==3 && safeTail(f,n) && f.helper.client.adoptions==1 && f.helper.client.recovers==1 && f.helper.client.commits==0 && f.app.profileService.cache.saves==0 && VPNProfileService.dnsCalls==0
  }
  let steps=["promotion-before-WAL-write","promotion-after-WAL-write","promotion-after-WAL-readback","promotion-before-nonce-remove","promotion-after-nonce-remove","promotion-before-capability-remove","promotion-after-capability-remove","promotion-before-purpose-remove","promotion-after-purpose-remove","promotion-before-material-remove","promotion-after-material-remove","promotion-before-retired-write","promotion-after-retired-write","promotion-after-retired-readback"]
  for step in steps {
   await run("owned-IO-"+step+"-fresh-store-retry-fence-last") {
    let f=try await fresh(step),fence=try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner),n=f.helper.client.calls.count;var fired=false
    f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s==step{fired=true;throw ProbeError.injected}})
    await admit(f)
    guard fired,try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==fence else{return false}
    let wal=try f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner);reopen(f)
    if wal==nil {await admit(f);return try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil && safeTail(f,n)}
    let count=f.helper.client.calls.count;try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    guard try clean(f),try f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==fence,f.helper.client.calls.count==count+2 else{return false}
    await admit(f)
    return try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil && safeTail(f,n) && f.helper.client.adoptions==1 && f.helper.client.recovers==1 && f.helper.client.commits==0 && f.app.profileService.cache.saves==0
   }
  }
  for at in [2,3] {
   for fault in ["unknown","duplicate","CRLF","multiline","double-space","oversize","wrong-source","wrong-owner","pending","protocol","receipt-protocol","old-transaction","transport"] {
    await run("proof-\(at-1)-"+fault+"-no-WAL-no-private-write") {
     let f=try await fresh("proof\(at)"+fault),before=try privateHashes(f),n=f.helper.client.calls.count
     f.helper.client.legacyFault=fault;f.helper.client.legacyFaultAt=at;await admit(f)
     return try before==privateHashes(f) && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil && f.helper.client.normalReplies==at && safeTail(f,n) && f.helper.client.adoptions==1 && f.helper.client.recovers==1 && f.app.profileService.cache.saves==0
    }
   }
   for fault in ["account","token","install","helper","generation","desired","key","key-epoch","device","admission"] {
    await run("current-\(at-1)-"+fault+"-no-WAL-no-private-write") {
     let f=try await fresh("current\(at)"+fault),before=try privateHashes(f)
     f.helper.client.legacyFault=fault;f.helper.client.legacyFaultAt=at;await admit(f)
     return try before==privateHashes(f) && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil
    }
   }
   await run("nonce-reappears-proof-\(at-1)-preserve-present-nonce-and-custody") {
    let f=try await fresh("nonce\(at)"),before=try privateHashes(f);f.helper.client.legacyFault="nonce";f.helper.client.legacyFaultAt=at;await admit(f)
    var after=try privateHashes(f);after.removeValue(forKey:f.promotionURL().lastPathComponent)
    return try after==before && Data(contentsOf:f.promotionURL())==f.helper.client.nonceBytes && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil
   }
  }
  for missing in ["capability","purpose","both"] {
   await run("legacy-partial-"+missing+"-new-admission-not-secret-absence-authority") {
    let f=try await fresh(missing)
    // Represent old non-atomic cleanup without asking a production API to erase
    // custody. Purpose is optional for the journal fixture; add one when needed.
    try purpose(f)
    if missing != "purpose" {try FileManager.default.removeItem(at:recordPath(f,"restart-capability-"))}
    if missing != "capability" {try FileManager.default.removeItem(at:recordPath(f,"stage-consent-"))}
    await admit(f);return try clean(f) && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner)==nil
   }
  }
  for item in ["material","capability","fence","purpose"] {
   await run("changed-"+item+"-canonical-custody-preserved") {
    let f=try await fresh("changed-"+item)
    if item=="purpose"{try purpose(f)}
    let url=try recordPath(f,item=="material" ? "restart-material-":item=="capability" ? "restart-capability-":item=="purpose" ? "stage-consent-":"source-restoration-")
    var o=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];o["unknown"]=true;try writeObject(o,url)
    let before=try privateHashes(f);await admit(f);return try before==privateHashes(f) && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil
   }
  }
  await run("no-material-but-other-custody-denied-no-reconstruction") {
   let f=try await fresh("no-material");try FileManager.default.removeItem(at:recordPath(f,"restart-material-"));let before=try privateHashes(f);await admit(f)
   return try before==privateHashes(f) && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)==nil && f.app.nativeProtectedRestartStore.sourceRestorationFence(owner:f.app.owner) != nil
  }
  await run("expired-capability-cleanup-no-TTL-renewal") {
   let f=try await fresh("expired"),u=try recordPath(f,"restart-capability-");var o=try JSONSerialization.jsonObject(with:Data(contentsOf:u)) as! [String:Any];o["issuedAt"]=1;o["expiresAt"]=121;try writeObject(o,u)
   await admit(f);return try clean(f) && f.app.nativeProtectedRestartStore.promotionRetirement(owner:f.app.owner)?.capabilitySHA256 != nil
  }
  await run("metadata-bounded-owned-no-nonce-secret-config-account-or-TTL") {
   let f=try await fresh("metadata");await admit(f);let u=try recordPath(f,"promotion-retirement-"),d=try Data(contentsOf:u),s=String(decoding:d,as:UTF8.self),o=try JSONSerialization.jsonObject(with:d) as! [String:Any]
   let forbidden=[f.app.material.sourceConfig,f.app.material.candidateConfig,f.app.owner.accountID,f.app.owner.installationID,"expiresAt","issuedAt","nonceSHA256"]
   let mode=(try FileManager.default.attributesOfItem(atPath:u.path)[.posixPermissions] as! NSNumber).intValue
   return d.count<=16384 && mode==0o600 && o["kind"] as? String == "normal-admission-legacy-no-nonce" && !forbidden.contains{s.contains($0)}
  }
  for field in ["kind","nonceSHA256","sourceFenceSHA256","admittedProfileSHA256","admittedOwnerSHA256","unknown"] {
   await run("strict-legacy-WAL-"+field+"-denied-no-delete") {
    let f=try await fresh("wal"+field);var fired=false
    f.app.nativeProtectedRestartStore = .init(appDataURL:f.root,afterRetirementStep:{s in if s=="promotion-before-nonce-remove"{fired=true;throw ProbeError.injected}});await admit(f);guard fired else{return false};reopen(f)
    let u=try recordPath(f,"promotion-retirement-");var o=try JSONSerialization.jsonObject(with:Data(contentsOf:u)) as! [String:Any]
    if field=="kind"{o[field]="normal-admission"}else if field=="nonceSHA256"{o[field]=String(repeating:"a",count:64)}else if field=="unknown"{o[field]=true}else{o.removeValue(forKey:field)}
    try writeObject(o,u);let before=try privateHashes(f),bad=await retryDenied(f)
    return try bad && before==privateHashes(f)
   }
  }
  for action in [AppState.NativeProtectedRestartAction.authorize,.recover,.resumeCandidate,.restoreSource,.cancel] {
   await run("pre-WAL-absence-no-authority-\(String(describing:action))-no-RPC") {
    let f=try await fresh("deny\(action)"),before=try privateHashes(f),n=f.helper.client.calls.count,bad=await retryDenied(f,action)
    return try bad && before==privateHashes(f) && f.helper.client.calls.count==n
   }
  }
  print("legacy_private_retirement_matrix cases=\(cases) failures=\(failures) live_network_commands=0");exit(failures==0 ? 0:1)
 }
}
'''
execute(v['FILES'],H+'\n'+v['COMMON']+'\n'+MAIN,'legacy_private_retirement',84)
