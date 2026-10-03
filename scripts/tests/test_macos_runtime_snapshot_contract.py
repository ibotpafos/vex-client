#!/usr/bin/env python3
"""Actual helper Runtime -> client coordinator, plus signed App cutover.

Root command/firewall/files/process/authentication ports are inert fixtures.
Only bounded private app metadata uses the disposable, owned temporary folder.
No installed app/helper, sockets, Keychain, API, DNS, routes or PF run here.
The internal controller snapshot is NOT the public Runtime wire contract.
"""
from pathlib import Path
import ast
import os
import re
import runpy
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
MODE = sys.argv[2] if len(sys.argv) > 2 else "wire"
S = ROOT / "macos-native/Sources/VEXNativeMac"
P = S / "Services"
CORE = ROOT / "macos-native/Sources/VEXHelperCore"


def literal(path, name):
    tree = ast.parse(path.read_text())
    return next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))


prefix = literal(ROOT / "scripts/tests/test_macos_protected_replacement.py", "HARNESS").split("// Child processes only", 1)[0]
prefix = prefix.replace("final class Fixture {", "final class KernelFixture {")
prefix = prefix.replace('var currentIF = "utun7", up = 0, down = 0',
                        'var currentIF = "utun7", up = 0, down = 0\n var handshake: UInt64 = 1')
prefix = prefix.replace(r'\t1\t12\t13\t25', r'\t\(handshake)\t12\t13\t25')
prefix = prefix.replace('var data: [String: String] = [:]', 'var data: [String: String] = [:]; var modes: [String: Int] = [:]')
prefix = prefix.replace('try beforeWrite?(path, text); data[path] = text;', 'try beforeWrite?(path, text); modes[path] = mode; data[path] = text;')
prefix = prefix.replace('runner: runner, firewall: pf)', 'runner: runner, firewall: pf, dateProvider: Clock.shared)')
prefix = prefix.replace('files.data[paths.activeConfigPath] == candidateConfig', 'files.data[paths.activeConfigPath] == files.data[paths.defaultConfigPath]')
prefix += literal(ROOT / "scripts/tests/test_macos_protected_owner_transfer.py", "HARNESS").split("let transferPath", 1)[0]

RPC = r'''
@MainActor final class RPC {
 let f=KernelFixture(), ids=Identities(), auth=Auth(), log=Log()
 var runtime:HelperRuntime!
 var calls:[String]=[],originalSnapshot="",rootNonce="",mode="",snapshots=0,auths=0
 init()throws {
  Clock.shared.seconds=Double(UInt64(Date().timeIntervalSince1970))
  f.runner.handshake=UInt64(Clock.shared.seconds)
  try HelperStateStore(fileSystem:f.files,paths:paths).persistSession(f.source)
  restart()
 }
 func restart(){runtime=HelperRuntime(store:HelperStateStore(fileSystem:f.files,paths:paths,dateProvider:Clock.shared),
  tunnelController:f.controller,firewallController:f.pf,processInspector:ids,dateProvider:Clock.shared,
  logger:log,protectedPeerAuthenticator:auth)}
 func send(_ command:String,_ timeout:Int=15)async throws->String {
  calls.append(command)
  let verb=String(command.split(separator:" ").first!)
  let response=await runtime.handle(commandLine:command,peerPID:123,
   authenticatedPeer:PeerCredentials(pid:123,auditToken:Data([7]),effectiveUID:501)).payload
  if verb=="protected-snapshot" {
   snapshots+=1
   if response.contains(" recovery_pending=false ") {
    originalSnapshot=response
    rootNonce=String(response.split(whereSeparator:\.isWhitespace).first{$0.hasPrefix("transaction_id=")}!.dropFirst("transaction_id=".count))
    if mode=="unknown" {return String(response.dropLast())+" unknown=1\n"}
    if mode=="CRLF" {return String(response.dropLast())+"\r\n"}
    if mode=="tab" {return response.replacingOccurrences(of:" ",with:"\t")}
    if mode=="multiline" {return response.replacingOccurrences(of:" ",with:"\n")}
    if mode=="double-space" {return response.replacingOccurrences(of:" ",with:"  ")}
    if mode=="leading-space" {return " "+response}
    if mode=="trailing-space" {return String(response.dropLast())+" \n"}
    if mode=="lower-uuid" {return response.replacingOccurrences(of:rootNonce,with:rootNonce.lowercased())}
    if mode=="bad-uuid" {return response.replacingOccurrences(of:rootNonce,with:"not-a-uuid")}
    if mode=="duplicate" {return String(response.dropLast())+" transaction_id="+rootNonce+"\n"}
    if mode=="internal-only" {return response.replacingOccurrences(of:" transaction_id="+rootNonce,with:"")}
    if mode=="legacy-no-receipt" {return response.replacingOccurrences(of:" commit_receipt_protocol=1",with:"")}
    if mode=="missing-owner" {return response.replacingOccurrences(of:"owner_token_sha256="+digest("fixture-intent")+" ",with:"")}
    if mode=="wrong-owner" {return response.replacingOccurrences(of:digest("fixture-intent"),with:digest("foreign"))}
    if mode=="wrong-source" {return response.replacingOccurrences(of:digest(sourceConfig),with:digest("foreign"))}
    if mode=="pending" {return response.replacingOccurrences(of:"recovery_pending=false",with:"recovery_pending=true")}
    if mode=="bad-receipt" {return response.replacingOccurrences(of:"commit_receipt_protocol=1",with:"commit_receipt_protocol=2")}
    if mode=="oversize" {return String(repeating:"x",count:4097)+"\n"}
    if mode=="no-newline" {return String(response.dropLast())}
    if mode=="NUL" {return String(response.dropLast())+"\0\n"}
   }
  }
  if verb=="protected-authorize-stage" {auths+=1;if mode=="lost-stage" && auths==1 {throw HelperError.io("inert lost stage ACK")}}
  return response
 }
 var untouched:Bool {f.runner.up==0 && f.runner.down==0 && f.pf.updates==0 && f.pf.enables==0 && f.pf.disables==0 && f.pf.active}
 var metadata:String {"transaction_id=\(rootNonce) source_sha256=\(digest(sourceConfig)) candidate_sha256=\(digest(candidateConfig)) owner_token_sha256=\(digest("fixture-intent"))"}
}
'''

WIRE = r'''
@MainActor final class Cutover {
 let rpc:RPC,coordinator=NativeProtectedReplacementCoordinator(),store:NativeProtectedPromotionStore
 let p:NativeProtectedReplacementCoordinator.Persistence
 var current=true,stages=0,restores=0,savedID="",custody=false
 var afterSnapshot:(()->Void)?,afterSave:(()->Void)?
 init(_ name:String)throws {
  rpc=try RPC()
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  store=NativeProtectedPromotionStore(appDataURL:root)
  p=try store.persistence(accountID:"fixture-account",installationID:"fixture-install",scopeFingerprint:digest("scope"),generation:12)
 }
 func replace(optIn:Bool=true,durable:Bool=true)async throws->NativeProtectedReplacementCoordinator.Receipt {
  var persistence=p
  persistence.save={data in try self.p.save(data);self.afterSave?()}
  return try await coordinator.replace(sourceSHA256:digest(sourceConfig),candidateSHA256:digest(candidateConfig),sourceOwnerTokenSHA256:digest("fixture-intent"),dependencies:.init(
   isCurrent:{self.current},send:{command,timeout in let reply=try await self.rpc.send(command,timeout);if command=="protected-snapshot" {self.afterSnapshot?()};return reply},
   stageCandidate:{
    self.stages+=1
    if durable {guard let data=try self.p.load() else {throw HelperError.io("private nonce absent")}
     let intent=try NativeProtectedReplacementCoordinator.restartIntent(data);self.savedID=intent.transactionID
     self.custody=intent.transactionID==self.rpc.rootNonce && intent.sourceSHA256==digest(sourceConfig) && intent.candidateSHA256==digest(candidateConfig) && intent.ownerTokenSHA256==digest("fixture-intent")}
    self.rpc.f.files.data[paths.defaultConfigPath]=candidateConfig
   },restoreSource:{self.restores+=1},wait:{},persistence:durable ? persistence:nil,
   stageConsent:optIn ? {intent,send in
    guard let data=try self.p.load() else {throw HelperError.io("private nonce absent")}
    try NativeProtectedReplacementCoordinator.requireUnconsumedStageIntent(data,original:intent)
    let metadata="transaction_id=\(intent.transactionID) source_sha256=\(intent.sourceSHA256) candidate_sha256=\(intent.candidateSHA256) owner_token_sha256=\(intent.ownerTokenSHA256) restart_capability="+String(repeating:"cd",count:32)
    let reply=try await send("protected-authorize-stage "+metadata,15)
    guard reply.hasPrefix("stage-authorized transaction_id="+intent.transactionID+" expires_at=") else {throw HelperError.io("stage denied")}
   }:nil))
 }
}
Task { @MainActor in
 var cases=0,failures=0
 func test(_ name:String,_ body:()async throws->Void)async {
  cases+=1;do{try await body();print("runtime_snapshot \(name)=PASS")}catch{failures+=1;print("runtime_snapshot \(name)=FAIL")}
 }
 @MainActor func nonce(_ c:Cutover,id:String=UUID().uuidString,process:String?=nil,scope:String?=nil)throws->Data {
  let processID:String
  if let process {processID=process} else {processID=NativeProtectedReplacementCoordinator.processInstanceID}
  var data=try JSONSerialization.data(withJSONObject:["schema":1,"scopeFingerprint":scope ?? c.p.scopeFingerprint,
   "processInstanceID":processID,"generation":12,"transaction":["id":id,"source":digest(sourceConfig),"candidate":digest(candidateConfig),
   "owner":digest("fixture-intent"),"supportsCommitReceipt":true,"commitResponseUncertain":false,"stageConsentPending":true]],options:[.sortedKeys])
  data.append(10);return data
 }
 await test("internal-five-public-six-owned-root-one-use-nonce") {
  let r=try RPC(),owner=OwnerSession(payload:r.f.files.data[paths.ownerSessionPath]!)!
  let internalValue=try r.f.controller.protectedReplacementSnapshot(validateOwner:{owner})
  let publicValue=try await r.send("protected-snapshot")
  try check(internalValue.split(whereSeparator:\.isWhitespace).count==5 && !internalValue.contains("transaction_id="),"internal five")
  try check(publicValue.split(whereSeparator:\.isWhitespace).count==6 && UUID(uuidString:r.rootNonce)?.uuidString==r.rootNonce && r.untouched,"public six")
 }
 for optIn in [false,true] {
  await test("actual-runtime-client-success-optIn-\(optIn)") {
   let c=try Cutover("success-\(optIn)"),receipt=try await c.replace(optIn:optIn)
   try check(c.savedID==c.rpc.rootNonce && c.custody && receipt.transactionID==c.savedID && c.stages==1 && c.restores==0,"root nonce persisted before stage")
   try check(c.rpc.f.runner.up==1 && c.rpc.f.runner.down==1 && c.rpc.f.pf.active && c.rpc.f.pf.disables==0,"inert exact protected transition")
   try check(c.rpc.auths==(optIn ? 1:0),"default no pre-stage opt in")
   let before=c.rpc.f.runner.down+c.rpc.f.runner.up
   let replay=try await c.rpc.send("protected-replace "+c.rpc.metadata)
   try check(replay.hasPrefix("error:") && c.rpc.f.runner.down+c.rpc.f.runner.up==before,"consumed nonce cannot replay")
  }
 }
 await test("existing-no-persistence-default-compatibility") {
  let c=try Cutover("in-memory"),receipt=try await c.replace(optIn:false,durable:false)
  try check(receipt.transactionID==c.rpc.rootNonce && c.stages==1 && c.rpc.auths==0 && c.rpc.f.pf.disables==0,"current default path")
 }
 await test("older-five-field-with-root-nonce-no-receipt-compatibility") {
  let c=try Cutover("legacy-no-receipt");c.rpc.mode="legacy-no-receipt"
  let receipt=try await c.replace(optIn:false,durable:false)
  try check(receipt.transactionID==c.rpc.rootNonce && c.stages==1 && c.rpc.f.pf.disables==0,"old field format, never an allocated client ID")
 }
 for mode in ["unknown","CRLF","tab","multiline","double-space","leading-space","trailing-space","lower-uuid","bad-uuid","duplicate","internal-only","missing-owner","wrong-owner","wrong-source","pending","bad-receipt","oversize","no-newline","NUL"] {
  for optIn in [false,true] {
   await test("deny-\(mode)-before-private-write-or-stage-optIn-\(optIn)") {
    let c=try Cutover("deny-\(mode)-\(optIn)");c.rpc.mode=mode
    var denied=false;do{_=try await c.replace(optIn:optIn)}catch{denied=true}
    try check(denied && c.stages==0 && c.restores==0 && c.rpc.auths==0 && c.rpc.untouched && (try c.p.load())==nil,"no mutation before exact wire proof")
   }
  }
 }
 await test("stale-after-real-snapshot-no-private-write") {
  let c=try Cutover("stale-snapshot");c.afterSnapshot={c.current=false}
  var denied=false;do{_=try await c.replace()}catch{denied=true}
  try check(denied && c.stages==0 && c.rpc.untouched && (try c.p.load())==nil,"fresh currentness")
 }
 await test("stale-after-private-write-no-root-or-stage") {
  let c=try Cutover("stale-save");c.afterSave={c.current=false}
  var denied=false;do{_=try await c.replace()}catch{denied=true}
  try check(denied && c.stages==0 && c.rpc.auths==0 && c.rpc.untouched && (try c.p.load()) != nil,"inert private evidence retained")
 }
 await test("lost-authorize-ACK-retry-exact-root-nonce-no-TTL-renewal") {
  let c=try Cutover("lost-stage");c.rpc.mode="lost-stage"
  var denied=false;do{_=try await c.replace()}catch{denied=true}
  let first=try c.p.load()!,intent=try NativeProtectedReplacementCoordinator.restartIntent(first)
  let grant=c.rpc.f.files.data[paths.helperDirectory+"/protected-pre-stage-consent.state"]!
  c.rpc.mode="";let receipt=try await c.replace()
  let calls=c.rpc.calls.filter{$0.hasPrefix("protected-authorize-stage ")}
  try check(denied && receipt.transactionID==intent.transactionID && calls.count==2 && calls[0]==calls[1] && c.rpc.snapshots==1,"same nonce and capability retry")
  try check(c.rpc.f.files.data[paths.helperDirectory+"/protected-pre-stage-consent.state"]==grant,"immutable original expiry")
 }
 await test("client-invented-nonce-denied-by-real-root") {
  let r=try RPC();_=try await r.send("protected-snapshot")
  let request=r.metadata.replacingOccurrences(of:r.rootNonce,with:UUID().uuidString)
  let denied=try await r.send("protected-replace "+request)
  try check(denied.hasPrefix("error:") && r.untouched,"no client nonce authority")
 }
 await test("root-grant-expiry-denied-without-client-reconstruction") {
  let c=try Cutover("expired");c.afterSave={Clock.shared.seconds+=31}
  var denied=false;do{_=try await c.replace()}catch{denied=true}
  try check(denied && c.rpc.untouched && c.rpc.auths==1 && (try c.p.load()) != nil && c.rpc.snapshots==1,"no renewal or fallback")
 }
 await test("foreign-nonce-races-snapshot-denied-no-overwrite") {
  let c=try Cutover("foreign-race"),foreign=try nonce(c)
  c.afterSnapshot={try! c.p.save(foreign)}
  var denied=false;do{_=try await c.replace()}catch{denied=true}
  try check(denied && c.stages==0 && c.rpc.untouched && (try c.p.load())==foreign,"exact owned CAS")
 }
 await test("same-root-nonce-private-write-idempotent") {
  let c=try Cutover("same-root-race")
  c.afterSnapshot={try! c.p.save(nonce(c,id:c.rpc.rootNonce))}
  let receipt=try await c.replace()
  try check(c.custody && receipt.transactionID==c.rpc.rootNonce && c.rpc.snapshots==1,"same exact fresh proved tuple")
 }
 for kind in ["old-process","foreign-scope","unknown-field","unsafe-mode"] {
  await test("existing-\(kind)-no-new-nonce-or-rpc") {
   let c=try Cutover("existing-"+kind)
   let bytes=try nonce(c,process:kind=="old-process" ? UUID().uuidString:NativeProtectedReplacementCoordinator.processInstanceID,
    scope:kind=="foreign-scope" ? digest("other-scope"):nil)
   let raw=NativePushSecureFileStore(rootURL:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("existing-"+kind),maxBytes:16384)
   let name="promotion-"+NativeProtectedPromotionStore.fingerprint(["vex-protected-promotion-v1","fixture-account","fixture-install"])+".json"
   var altered=bytes
   if kind=="unknown-field" {var object=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];object["unknown"]=1;altered=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);altered.append(10)}
   try raw.write(altered,name:name)
   let path=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("existing-"+kind).appendingPathComponent("push-psk-events").appendingPathComponent(name)
   if kind=="unsafe-mode" {precondition(chmod(path.path,0o644)==0)}
   var denied=false;do{_=try await c.replace()}catch{denied=true}
   try check(denied && c.stages==0 && c.rpc.calls.isEmpty && c.rpc.untouched && (try Data(contentsOf:path))==altered,"unchanged original custody")
  }
 }
 await test("private-write-lost-ACK-retry-keeps-root-id") {
  let c=try Cutover("private-lost-ack")
  var persistence=c.p
  persistence.save={data in try c.p.save(data);throw HelperError.io("inert private ACK loss")}
  var denied=false
  do{_=try await c.coordinator.replace(sourceSHA256:digest(sourceConfig),candidateSHA256:digest(candidateConfig),sourceOwnerTokenSHA256:digest("fixture-intent"),dependencies:.init(
   isCurrent:{true},send:{try await c.rpc.send($0,$1)},stageCandidate:{throw HelperError.io("stage forbidden before ACK")},restoreSource:{},persistence:persistence,stageConsent:{_,_ in throw HelperError.io("authorize forbidden before ACK")}))}catch{denied=true}
  let bytes=try c.p.load()!,before=try NativeProtectedReplacementCoordinator.restartIntent(bytes)
  let receipt=try await c.replace()
  try check(denied && receipt.transactionID==before.transactionID && receipt.transactionID==c.rpc.rootNonce && c.rpc.snapshots==1 && c.rpc.auths==1,"same durable nonce, no snapshot/ID regeneration")
 }
 print("runtime_snapshot_matrix cases=\(cases) failures=\(failures) live_network_commands=0 OS_crash_acceptance=not_claimed")
 exit(failures==0 ? 0:1)
}
RunLoop.main.run()
'''

if MODE == "app":
    # Read-only fixture builders; their historical mains do not execute.
    v = runpy.run_path(str(Path(__file__).with_name("test_macos_pre_stage_client_consent.py")), run_name="runtime_app_fixture")
    h = v["H"]
    h = h.replace("enum HelperError:Error", "enum FixtureHelperError:Error").replace("HelperError.protocolViolation", "FixtureHelperError.protocolViolation")
    h = h.replace("typealias AwgConfigAdmission=ActualAwgConfigAdmission\n", "", 1)
    h = h.replace(v["body"](h, "enum SystemTunnelController"), "")
    start = h.index("@MainActor final class Client {")
    end = h.index("@MainActor final class VEXHelperModel {", start)
    client = r'''
@MainActor final class Client {
 unowned let app:AppState;let root:RPC
 var calls:[String]=[],mode="",adoptions=0,proofs=0
 let newOwner=String(repeating:"b",count:64)
 init(_ app:AppState){self.app=app;root=try! RPC()
  root.f.files.data[paths.activeConfigPath]=app.material.sourceConfig
  root.f.files.data[paths.defaultConfigPath]=app.material.candidateConfig
  root.f.source.endpoint="203.0.113.7:51820"
  try! HelperStateStore(fileSystem:root.f.files,paths:paths).persistSession(root.f.source)
 }
 func stage(_ config:String){root.f.files.data[paths.defaultConfigPath]=config}
 func send(_ command:String,timeoutSeconds:Int)async throws->String {
  calls.append(command)
  if command.hasPrefix("protected-receipt"){proofs+=1}
  if command.hasPrefix("protected-authorize-stage") || command.hasPrefix("protected-replace ") {
   guard let m=try app.nativeProtectedRestartStore.loadMaterial(owner:app.owner),
    let p=try app.nativeProtectedPromotionStore.persistence(accountID:app.owner.accountID,installationID:app.owner.installationID,scopeFingerprint:m.intent.scopeFingerprint,generation:m.intent.generation).load(),
    m.intent.transactionID==root.rootNonce,app.profileService.stageWrites>0 else{throw ProbeError.injected}
   guard try NativeProtectedReplacementCoordinator.restartIntent(p)==m.intent else{throw ProbeError.injected}
   if command.hasPrefix("protected-authorize-stage") {
    guard let cap=try app.nativeProtectedRestartStore.loadCapability(owner:app.owner,material:m),
     try app.nativeProtectedRestartStore.stageConsent(owner:app.owner,material:m) != nil,
     command.contains("restart_capability="+cap.value) else{throw ProbeError.injected}
    try NativeProtectedReplacementCoordinator.requireUnconsumedStageIntent(p,original:m.intent)
   }
  }
  return try await root.send(command,timeoutSeconds)
 }
}
'''
    h = h[:start] + client + h[end:]
    h = h.replace("try validateCurrent();stageWrites+=1}", "try validateCurrent();stageWrites+=1;stagePort?(config)}")
    h = h.replace('var canonicalCandidate="",stageWrites=0,prepares=0', 'var canonicalCandidate="",stageWrites=0,prepares=0\n var stagePort:((String)->Void)?')
    app_main = r'''
Task { @MainActor in
 var cases=0,failures=0
 for optIn in [false,true] {
  cases+=1
  do {
   let f=try Fixture("actual-runtime-app-\(optIn)",oldProcess:false)
   try f.app.nativeProtectedRestartStore.removeMaterial(owner:f.app.owner,expected:f.app.material)
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.activeTunnel=f.source;f.app.nativePSKPreparedTunnel=f.source;f.app.desiredVpnState = .connected
   f.app.nativeProtectedStageConsentEnabled=optIn;f.app.vpnOperationGeneration=11
   f.app.profileService.canonicalCandidate=f.app.material.candidateConfig
   f.app.profileService.stagePort={config in f.helper.client.stage(config)}
   _=try f.app.nativeAdmittedProfiles.record(tunnel:f.source,canonicalConfig:f.app.material.sourceConfig,
    ownerTokenSHA256:digest("fixture-intent"),scope:try f.app.nativeAdmittedProfileScope(for:f.source),helper:f.helper)
   _=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)
   let r=f.helper.client.root
   try check(r.originalSnapshot.split(whereSeparator:\.isWhitespace).count==6 && UUID(uuidString:r.rootNonce)?.uuidString==r.rootNonce,"real public wire nonce")
   try check(r.f.runner.up==1 && r.f.runner.down==1 && r.f.pf.active && r.f.pf.disables==0 && r.auths==(optIn ? 1:0),"only inert physical ports")
   try check(f.app.activeTunnel?.profileVersion==2 && f.app.profileService.cache.saves==1 && f.app.profileService.prepares==1 && f.helper.client.proofs==(optIn ? 1:0),"actual signed App/helper admission and cache")
   try check(try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID),"actual exact private retirement")
   print("runtime_snapshot_app signed-app-to-real-runtime-optIn-\(optIn)=PASS")
  }catch{failures+=1;print("runtime_snapshot_app signed-app-to-real-runtime-optIn-\(optIn)=FAIL \(error)")}
 }
 print("runtime_snapshot_app_matrix cases=\(cases) failures=\(failures) live_network_commands=0 installed_helper_acceptance=not_claimed")
 exit(failures==0 ? 0:1)
}
RunLoop.main.run()
'''
    prefix = prefix.replace("signal(SIGPIPE, SIG_IGN)", "")
    HARNESS = prefix + RPC + h + app_main
    native = [S / "Models/VEXModels.swift"] + [P / n for n in [
        "VPNProfileCache.swift", "NativeAwgBoolean.swift", "NativePSKIdentifier.swift", "NativePushPSKEventQueue.swift",
        "NativePushSecureFileStore.swift", "NativePSKStagedProfileStore.swift", "NativePSKRotationValidation.swift",
        "NativeVPNProfileAuthorizationVerifier.swift", "NativeAdmittedProfileStore.swift",
        "NativeProtectedReplacementCoordinator.swift", "NativeProtectedPromotionStore.swift",
        "NativeProtectedRestartStore.swift", "NativeProtectedRestartCoordinator.swift"]]
else:
    HARNESS = prefix + RPC + WIRE
    native = [P / n for n in ["NativePushSecureFileStore.swift", "NativeProtectedReplacementCoordinator.swift", "NativeProtectedPromotionStore.swift"]]

with tempfile.TemporaryDirectory(prefix="runtime-snapshot-", dir=Path(os.environ.get("TMPDIR", "/private/tmp")).resolve()) as raw:
    d = Path(raw)
    (d / "main.swift").write_text(HARNESS)
    data = d / "owned-app-data"
    data.mkdir(mode=0o700)
    command = ["rtk", "proxy", "swiftc", "-swift-version", "5", *map(str, sorted(CORE.glob("*.swift"))),
               *map(str, native), str(d / "main.swift"), "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm", "-o", str(d / "probe")]
    r = subprocess.run(command, capture_output=True)
    sys.stdout.buffer.write(r.stdout)
    sys.stderr.buffer.write(r.stderr)
    if r.returncode:
        raise SystemExit(r.returncode)
    r = subprocess.run(["rtk", "proxy", str(d / "probe"), str(data)], capture_output=True, timeout=120)
    sys.stdout.buffer.write(r.stdout)
    sys.stderr.buffer.write(r.stderr)
    marker = "runtime_snapshot_app" if MODE == "app" else "runtime_snapshot"
    names = [line.split(" ")[1].split("=")[0] for line in r.stdout.decode().splitlines() if line.startswith(marker + " ")]
    expected = 2 if MODE == "app" else 55
    if len(names) != expected or len(set(names)) != expected or not re.search(rb"_matrix cases=" + str(expected).encode() + rb" failures=\d+", r.stdout):
        raise SystemExit(1)
    raise SystemExit(r.returncode)
