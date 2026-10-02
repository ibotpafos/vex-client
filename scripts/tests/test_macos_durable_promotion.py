#!/usr/bin/env python3
"""Actual app coordinator/private metadata store; disposable disk and inert RPC only."""
from pathlib import Path
import ast
import os
import subprocess
import sys
import tempfile

ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac/Services'
source=S/'NativeProtectedReplacementCoordinator.swift'
# This adjacent frozen dependency supplies only literal inert RPC/config ports.
tree=ast.parse((Path(__file__).parent/'test_macos_protected_coordinator.py').read_text())
wire=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='HARNESS' for t in n.targets))
wire=wire.split('@main struct Main {')[0]
supported='struct Persistence' in source.read_text()
BASELINE=r'''
@main struct Main {
 @MainActor static func main() async {
  var failures=0,cases=0
  func check(_ name:String,_ value:Bool){cases+=1;if !value{failures+=1};print("durable_promotion \(name)=\(value ? "PASS":"FAIL")")}
  let w=Wire(),first=NativeProtectedReplacementCoordinator()
  do {
   let receipt=try await first.replace(sourceSHA256:w.source,candidateSHA256:w.candidate,sourceOwnerTokenSHA256:w.owner,dependencies:w.dependencies)
   let fresh=NativeProtectedReplacementCoordinator()
   var replay=false
   do{let value=try await fresh.replace(sourceSHA256:w.source,candidateSHA256:w.candidate,sourceOwnerTokenSHA256:w.owner,dependencies:w.dependencies);replay=value==receipt}catch{}
   check("coordinator-recreation-reconciles-exact-commit",replay && w.staged==1 && w.polls==1 && w.restored==0)
   var revalidated=false
   do{try await fresh.revalidateCommitted(receipt,isCurrent:{true},send:{try await w.send($0,$1)});revalidated=true}catch{}
   check("cache-proof-survives-coordinator-recreation",revalidated)
   check("private-intent-written-before-RPC",false)
  }catch{check("coordinator-recreation-reconciles-exact-commit",false);check("cache-proof-survives-coordinator-recreation",false);check("private-intent-written-before-RPC",false)}
  print("durable_promotion_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0:1)
 }
}
'''
MODIFIED=r'''
import Darwin
@MainActor final class Disk {
 let w=Wire(),root:URL,store:NativeProtectedPromotionStore
 var scope=NativeProtectedReplacementCoordinator.digest("intent"),generation=11,failInitial=false,failConfirmed=false,failRemove=false
 init(_ name:String) {root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name,isDirectory:true);store=NativeProtectedPromotionStore(appDataURL:root)}
 func persistence()throws->NativeProtectedReplacementCoordinator.Persistence {
  var p=try store.persistence(accountID:"fixture-account",installationID:"fixture-install",scopeFingerprint:scope,generation:generation)
  let save=p.save,remove=p.remove
  p.save={data in let hasReceipt=(try JSONSerialization.jsonObject(with:data) as! [String:Any])["receipt"] != nil;if self.failInitial || (self.failConfirmed && hasReceipt){throw ProbeError.injected};try save(data)}
  p.remove={data in if self.failRemove{throw ProbeError.injected};try remove(data)}
  return p
 }
 func dependencies(_ p:NativeProtectedReplacementCoordinator.Persistence)->NativeProtectedReplacementCoordinator.Dependencies {
  var d=w.dependencies;d.persistence=p
  d.send={command,timeout in let response=try await self.w.send(command,timeout);if command=="protected-snapshot" && !response.contains("commit_receipt_protocol="){return String(response.dropLast())+" commit_receipt_protocol=1\n"};return response}
  return d
 }
 func run(_ c:NativeProtectedReplacementCoordinator,_ p:NativeProtectedReplacementCoordinator.Persistence,candidate:String?=nil,owner:String?=nil)async throws->NativeProtectedReplacementCoordinator.Receipt {
  try await c.replace(sourceSHA256:w.source,candidateSHA256:candidate ?? w.candidate,sourceOwnerTokenSHA256:owner ?? w.owner,dependencies:dependencies(p))
 }
 var file:URL {try! FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix("promotion-")})!}
 func tamper(_ change:(inout [String:Any])->Void)throws {
  var object=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];change(&object)
  var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10)
  try NativePushSecureFileStore(rootURL:root,maxBytes:16384).write(data,name:file.lastPathComponent)
 }
}
@main struct Main {
 @MainActor static func main() async {
  var cases=0,failures=0
  func check(_ name:String,_ value:Bool){cases+=1;if !value{failures+=1};print("durable_promotion \(name)=\(value ? "PASS":"FAIL")")}
  do {
   let s=Disk("write-order"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence();var before=false
   s.w.onReady={before=(try? p.load()) != nil}
   let receipt=try await s.run(c,p);var info=stat();precondition(lstat(s.file.path,&info)==0)
   let text=String(data:try p.load()!,encoding:.utf8)!
   check("private-intent-before-RPC-no-secret-fields",before && info.st_mode & 0o777==0o600 && !text.contains("fixture-account") && !text.contains("fixture-install") && !text.contains(":\"source\"") && !text.contains("config") && !text.contains("access_token"))
   let fresh=NativeProtectedReplacementCoordinator(),value=try await s.run(fresh,p)
   check("coordinator-recreation-reconciles-exact-commit",value==receipt && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
   let another=NativeProtectedReplacementCoordinator()
   try await another.revalidateCommitted(receipt,isCurrent:{true},send:{try await s.w.send($0,$1)},persistence:p)
   check("cache-proof-survives-coordinator-recreation",s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
   try another.completeCommitted(receipt,persistence:p)
   check("complete-after-cache-removes-only-intent",try p.load()==nil && !s.store.hasRecord(accountID:"fixture-account",installationID:"fixture-install"))
  }catch{check("write-order-or-recreation",false)}
  do {
   let s=Disk("initial-io"),c=NativeProtectedReplacementCoordinator();s.failInitial=true;let p=try s.persistence();var denied=false
   do{_=try await s.run(c,p)}catch{denied=true}
   check("initial-write-failure-before-stage-or-replace",try denied && s.w.staged==0 && s.w.polls==0 && s.w.restored==0 && s.w.calls==["protected-snapshot"] && p.load()==nil)
  }catch{check("initial-write-failure-before-stage-or-replace",false)}
  do {
   let s=Disk("confirmed-io"),c=NativeProtectedReplacementCoordinator();s.failConfirmed=true;let p=try s.persistence()
   let receipt=try await s.run(c,p)
   check("post-commit-metadata-fault-retains-physical-truth",try c.hasUnconfirmedDurableWrite && receipt.candidateSHA256==s.w.candidate && s.w.committed && s.w.restored==0 && p.load() != nil)
   s.failConfirmed=false;let fresh=NativeProtectedReplacementCoordinator(),proof=try await s.run(fresh,try s.persistence())
   check("uncertain-record-retry-uses-original-nonce",proof==receipt && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
  }catch{check("confirmed-write-fault-or-retry",false)}
  do {
   let s=Disk("ambiguous"),c=NativeProtectedReplacementCoordinator();s.w.mode="durable-transient";let p=try s.persistence();var first=false
   do{_=try await s.run(c,p)}catch{first=true}
   let fresh=NativeProtectedReplacementCoordinator(),receipt=try await s.run(fresh,p)
   check("lost-ack-transient-proof-reload-no-duplicate",first && receipt.transactionID==s.w.id && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
  }catch{check("lost-ack-transient-proof-reload-no-duplicate",false)}
  do {
   let s=Disk("denied"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence(),receipt=try await s.run(c,p)
   s.w.mode="durable-denied";let fresh=NativeProtectedReplacementCoordinator();var denied=false,completion=false
   do{try await fresh.revalidateCommitted(receipt,isCurrent:{true},send:{try await s.w.send($0,$1)},persistence:p)}catch{denied=true}
   do{try fresh.completeCommitted(receipt,persistence:p)}catch{completion=true}
   check("denied-proof-cannot-adopt-or-complete",try denied && completion && p.load() != nil && s.w.staged==1 && s.w.restored==0)
  }catch{check("denied-proof-cannot-adopt-or-complete",false)}
  for mode in ["scope","generation","process","candidate","owner","unknown","corrupt","permission"] {
   do {
    let s=Disk("fence-"+mode),c=NativeProtectedReplacementCoordinator(),p=try s.persistence();_=try await s.run(c,p);let count=s.w.calls.count
    var altered=p
    if mode=="scope" {s.scope=NativeProtectedReplacementCoordinator.digest("other");altered=try s.persistence()}
    if mode=="generation" {s.generation += 1;altered=try s.persistence()}
    if mode=="process" {altered = .init(scopeFingerprint:p.scopeFingerprint,processInstanceID:UUID().uuidString,generation:p.generation,load:p.load,save:p.save,remove:p.remove)}
    if mode=="unknown" {try s.tamper{$0["unknown_secret"]="fixture-only"}}
    if mode=="corrupt" {try Data([0xff]).write(to:s.file);precondition(chmod(s.file.path,0o600)==0)}
    if mode=="permission" {precondition(chmod(s.file.path,0o644)==0)}
    var denied=false
    do{_=try await s.run(NativeProtectedReplacementCoordinator(),altered,candidate:mode=="candidate" ? s.w.source:nil,owner:mode=="owner" ? s.w.source:nil)}catch{denied=true}
    check("fenced-"+mode,denied && s.w.calls.count==count && s.w.staged==1 && s.w.polls==1 && s.w.restored==0 && FileManager.default.fileExists(atPath:s.file.path))
   }catch{check("fenced-"+mode,false)}
  }
  do {
   let s=Disk("remove-io"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence(),receipt=try await s.run(c,p);s.failRemove=true;var denied=false
   do{try c.completeCommitted(receipt,persistence:p)}catch{denied=true}
   check("remove-failure-retains-cache-only-retry",try denied && p.load() != nil && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
   s.failRemove=false;let q=try s.persistence(),fresh=NativeProtectedReplacementCoordinator()
   try await fresh.revalidateCommitted(receipt,isCurrent:{true},send:{try await s.w.send($0,$1)},persistence:q);try fresh.completeCommitted(receipt,persistence:q)
   check("remove-failure-retry-authenticates-without-replace",try q.load()==nil && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
  }catch{check("remove-failure-retry",false)}
  do {
   let s=Disk("wrong-completion"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence(),r=try await s.run(c,p);var denied=false
   let wrong=NativeProtectedReplacementCoordinator.Receipt(transactionID:UUID().uuidString,candidateSHA256:r.candidateSHA256,latestHandshake:r.latestHandshake,ownerTokenSHA256:r.ownerTokenSHA256)
   do{try c.completeCommitted(wrong,persistence:p)}catch{denied=true}
   check("wrong-completion-cannot-erase-intent",try denied && p.load() != nil)
   let absent=try s.store.hasRecord(accountID:"different-account",installationID:"fixture-install")
   check("other-account-namespace-does-not-adopt",try !absent && p.load() != nil)
  }catch{check("wrong-completion-or-namespace",false)}
  do {
   let s=Disk("initial-unknown"),p=try s.persistence();var denied=false
   do{try p.save(Data("{\"config\":\"fixture-secret\"}\n".utf8))}catch{denied=true}
   check("unknown-initial-payload-never-written",try denied && p.load()==nil && s.w.calls.isEmpty)
  }catch{check("unknown-initial-payload-never-written",false)}
  do {
   let s=Disk("late-proof"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence(),receipt=try await s.run(c,p)
   let fresh=NativeProtectedReplacementCoordinator();var denied=false,completion=false
   do{try await fresh.revalidateCommitted(receipt,isCurrent:{true},send:{command,timeout in let reply=try await s.w.send(command,timeout);try s.tamper{$0["generation"]=999};return reply},persistence:p)}catch{denied=true}
   do{try fresh.completeCommitted(receipt,persistence:p)}catch{completion=true}
   check("record-changed-during-proof-cannot-adopt",denied && completion && s.w.staged==1 && s.w.polls==1 && s.w.restored==0)
  }catch{check("record-changed-during-proof-cannot-adopt",false)}
  do {
   let s=Disk("purge-owner"),c=NativeProtectedReplacementCoordinator(),p=try s.persistence();_=try await s.run(c,p)
   let bytes=try p.load()!,other=try s.store.persistence(accountID:"other-account",installationID:"fixture-install",scopeFingerprint:p.scopeFingerprint,generation:p.generation)
   try other.save(bytes);let count=s.w.calls.count
   try s.store.purge(accountID:"fixture-account",installationID:"fixture-install")
   check("explicit-owner-purge-preserves-other-namespace",try p.load()==nil && other.load()==bytes && s.w.calls.count==count)
  }catch{check("explicit-owner-purge-preserves-other-namespace",false)}
  print("durable_promotion_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0:1)
 }
}
'''
if supported and not MODIFIED:
    raise SystemExit('new harness not yet defined')
scratch=Path(os.environ.get('TMPDIR','/private/tmp')).resolve()
with tempfile.TemporaryDirectory(prefix='durable-promotion-',dir=scratch) as raw:
    directory=Path(raw);(directory/'main.swift').write_text(wire+(MODIFIED if supported else BASELINE))
    files=[source]
    if supported:files += [S/'NativeProtectedPromotionStore.swift',S/'NativePushSecureFileStore.swift']
    subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',*map(str,files),str(directory/'main.swift'),'-o',str(directory/'probe')],check=True,timeout=180)
    data=directory/'app-data';data.mkdir(mode=0o700)
    raise SystemExit(subprocess.run(['rtk','proxy',str(directory/'probe'),str(data)],timeout=60).returncode)
