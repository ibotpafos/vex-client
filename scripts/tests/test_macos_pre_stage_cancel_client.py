#!/usr/bin/env python3
"""Actual App cancel, helper wrapper, nonce CAS and owned private file IO.

Authenticated RPC is an inert idempotent-cancellation port. Its root WAL
authority is separately compiled/verified by test_macos_pre_stage_cancel_receipt;
this is NOT installed app/helper or real OS crash acceptance.
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
contract = ROOT / "macos-native/Sources/VEXHelperCore/ProtectedPreStageConsent.swift"
if not contract.exists() or "struct ProtectedPreStageCancellationReceipt" not in contract.read_text():
    print("pre_stage_cancel_client contract=ABSENT (one diagnostic; root cancellation WAL missing; runtime branches NOT executed)")
    print("pre_stage_cancel_client_matrix cases=1 failures=1 live_network_commands=0")
    raise SystemExit(1)

v = runpy.run_path(str(Path(__file__).with_name("test_macos_pre_stage_client_consent.py")), run_name="cancel_client_fixture")
H = v["H"]
H = H.replace('var firstAuth="",source="",candidate=""', 'var firstAuth="",firstCancel="",source="",candidate="";var cancelProofWrites=0')
start = H.index('  case "protected-cancel-stage":')
end = H.index('  case "protected-recover":', start)
H = H[:start] + r'''
  case "protected-cancel-stage":
   cancels+=1;guard authorized,!journal else {throw ProbeError.injected}
   if firstCancel.isEmpty {firstCancel=command}
   if !cancelled {cancelled=true;cancelProofWrites+=1} // models observed root WAL; never a new authorization
   if mode=="lost-cancel" && cancels==1 {throw ProbeError.injected}
   if mode=="marker-write-denied" && cancels==1 {
    let url=try FileManager.default.contentsOfDirectory(at:app.fixtureRoot.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("stage-consent-")}!
    precondition(chmod(url.path,0o644)==0) // actual private-CAS/write guard fails after a valid root ACK
   }
   if mode=="cancel-private-cleanup-denied" && cancels==1 {
    let url=try FileManager.default.contentsOfDirectory(at:app.fixtureRoot.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("promotion-")}!
    precondition(chmod(url.path,0o644)==0)
   }
   if mode=="token-after-cancel" && cancels==1 {app.session!.accessToken="withdrawn"}
   let good="stage-cancelled transaction_id=\(t.transactionID)\n"
   switch mode {
   case "unknown":return String(good.dropLast())+" proof_sha256="+String(repeating:"0",count:64)+"\n"
   case "duplicate":return String(good.dropLast())+" transaction_id=\(t.transactionID)\n"
   case "wrong-id":return good.replacingOccurrences(of:t.transactionID,with:UUID().uuidString)
   case "empty":return ""
   case "error":return "error: denied\n"
   case "transport":throw ProbeError.injected
   case "CRLF":return String(good.dropLast())+"\r\n"
   case "multiline":return good+good
   case "oversize":return String(repeating:"x",count:4097)+"\n"
   case "tab":return good.replacingOccurrences(of:" ",with:"\t")
   case "nul":return String(good.dropLast())+"\0\n"
   case "spaces":return good.replacingOccurrences(of:" ",with:"  ")
   default:return good
   }
''' + H[end:]
MAIN = r'''
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0,names=Set<String>()
  func a(_ name:String,_ ok:Bool){cases+=1;let unique=names.insert(name).inserted;if !ok || !unique{failures+=1};print("pre_stage_cancel_client \(name)=\(ok && unique ? "PASS":"FAIL")")}
  func path(_ f:Fixture,_ prefix:String)throws->URL {
   guard let url=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("push-psk-events"),includingPropertiesForKeys:nil).first(where:{$0.lastPathComponent.hasPrefix(prefix)})else{throw ProbeError.injected};return url
  }
  func fresh(_ name:String)async throws->Fixture {
   let f=try Fixture(name,oldProcess:false)
   try f.app.nativeProtectedRestartStore.removeMaterial(owner:f.app.owner,expected:f.app.material)
   try f.app.nativeProtectedPromotionStore.purge(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
   f.app.activeTunnel=f.source;f.app.nativePSKPreparedTunnel=f.source;f.app.desiredVpnState = .connected
   f.app.nativeProtectedStageConsentEnabled=true;f.app.vpnOperationGeneration=11
   f.app.profileService.canonicalCandidate=f.app.material.candidateConfig
   _=try f.app.nativeAdmittedProfiles.record(tunnel:f.source,canonicalConfig:f.app.material.sourceConfig,
     ownerTokenSHA256:f.app.material.intent.ownerTokenSHA256,scope:try f.app.nativeAdmittedProfileScope(for:f.source),helper:f.helper)
   f.helper.client.mode="lost-authorize"
   var denied=false;do{_=try await f.app.cutover(f.envelope,source:f.source,helper:f.helper)}catch{denied=true}
   guard denied,f.helper.client.authorized,f.helper.client.replacements==0 else{throw ProbeError.injected}
   f.helper.client.mode="";return f
  }
  func retained(_ f:Fixture)throws->Bool {
   guard let m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner),
    let s=try f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:m),
    let cap=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:m)else{return false}
   return try !s.cancelled && cap.intent==m.intent && f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
  }
  func clean(_ f:Fixture)throws->Bool {
   try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)==nil && !f.app.nativeProtectedPromotionStore.hasRecord(accountID:f.app.owner.accountID,installationID:f.app.owner.installationID)
    && f.helper.client.replacements==0 && f.helper.client.commits==0 && f.helper.client.proofs==0 && f.helper.client.recoveries==0
    && !f.helper.client.calls.contains{$0.hasPrefix("protected-adopt") || $0.hasPrefix("protected-authorize-restart")}
    && f.app.profileService.cache.saves==0 && f.app.activeTunnel?.profileVersion==1 && VPNProfileService.dnsCalls==0
  }
  func denied(_ f:Fixture)async->Bool {do{try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper);return false}catch{return true}}
  do {
   let f=try await fresh("cancel-ACK-loss"),cap=try path(f,"restart-capability-"),nonce=try path(f,"promotion-")
   let cb=try Data(contentsOf:cap),nb=try Data(contentsOf:nonce)
   f.helper.client.mode="lost-cancel";let bad=await denied(f)
   a("lost-ACK-retains-exact-capability-nonce-and-unmarked-material",try bad && retained(f) && Data(contentsOf:cap)==cb && Data(contentsOf:nonce)==nb && f.helper.client.cancelProofWrites==1)
   f.helper.client.mode="";f.app.selectedLocationId="us";f.app.entitlement = .init(hasPaidAccess:false)
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   let c=f.helper.client,cmds=c.calls.filter{$0.hasPrefix("protected-cancel-stage ")}
   a("lost-ACK-exact-retry-cleans-without-reauthorization-adoption-or-admission",try clean(f) && cmds.count==2 && cmds[0]==cmds[1] && c.auths==1 && c.cancelProofWrites==1 && c.busyAtEveryRPC)
  }catch{a("lost-ACK-retains-exact-capability-nonce-and-unmarked-material",false);a("lost-ACK-exact-retry-cleans-without-reauthorization-adoption-or-admission",false)}
  do {
   let f=try await fresh("cancel-marker-IO"),cap=try path(f,"restart-capability-"),nonce=try path(f,"promotion-"),marker=try path(f,"stage-consent-")
   let cb=try Data(contentsOf:cap),nb=try Data(contentsOf:nonce),mb=try Data(contentsOf:marker)
   f.helper.client.mode="marker-write-denied";let bad=await denied(f)
   a("ACK-before-private-marker-write-denial-preserves-inert-bytes",try bad && Data(contentsOf:marker)==mb && Data(contentsOf:cap)==cb && Data(contentsOf:nonce)==nb && f.helper.client.cancelled && f.app.profileService.cache.saves==0)
   precondition(chmod(marker.path,0o600)==0);f.helper.client.mode=""
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   let cmds=f.helper.client.calls.filter{$0.hasPrefix("protected-cancel-stage ")}
   a("marker-write-denial-retry-uses-same-root-proof-capability-nonce",try clean(f) && cmds.count==2 && cmds[0]==cmds[1] && f.helper.client.cancelProofWrites==1 && f.helper.client.auths==1)
  }catch{a("ACK-before-private-marker-write-denial-preserves-inert-bytes",false);a("marker-write-denial-retry-uses-same-root-proof-capability-nonce",false)}
  for mode in ["unknown","duplicate","wrong-id","empty","error","transport","CRLF","multiline","oversize","tab","nul","spaces"] {
   do {
    let f=try await fresh("cancel-reply-"+mode),cap=try path(f,"restart-capability-"),nonce=try path(f,"promotion-")
    let cb=try Data(contentsOf:cap),nb=try Data(contentsOf:nonce)
    f.helper.client.mode=mode;let bad=await denied(f)
    let inert=try bad && retained(f) && Data(contentsOf:cap)==cb && Data(contentsOf:nonce)==nb
    f.helper.client.mode="";try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
    let cmds=f.helper.client.calls.filter{$0.hasPrefix("protected-cancel-stage ")}
    a("strict-ACK-"+mode+"-no-false-cleanup-exact-retry",try inert && clean(f) && cmds.count==2 && cmds[0]==cmds[1] && f.helper.client.cancelProofWrites==1)
   }catch{a("strict-ACK-"+mode+"-no-false-cleanup-exact-retry",false)}
  }
  do {
   let f=try await fresh("cancel-after-expiry"),cap=try path(f,"restart-capability-")
   var object=try JSONSerialization.jsonObject(with:Data(contentsOf:cap)) as! [String:Any]
   let issued=UInt64(Date().timeIntervalSince1970)-121;object["issuedAt"]=issued;object["expiresAt"]=issued+120
   var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);try data.write(to:cap);precondition(chmod(cap.path,0o600)==0)
   f.helper.client.mode="lost-cancel";let bad=await denied(f),bytes=try Data(contentsOf:cap)
   f.helper.client.mode="";try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   let cmds=f.helper.client.calls.filter{$0.hasPrefix("protected-cancel-stage ")}
   a("expired-capability-still-exact-cancel-not-TTL-renewal-or-stage",try bad && bytes==data && clean(f) && cmds.count==2 && cmds[0]==cmds[1] && f.helper.client.auths==1)
  }catch{a("expired-capability-still-exact-cancel-not-TTL-renewal-or-stage",false)}
  do {
   let f=try await fresh("cancel-current-withdrawal")
   f.helper.client.mode="token-after-cancel";let bad=await denied(f)
   a("token-withdrawal-after-ACK-does-not-mark-or-clean",try bad && retained(f) && f.app.profileService.cache.saves==0)
   f.app.session!.accessToken="fixture-token";f.helper.client.mode=""
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("same-current-owner-after-withdrawal-retries-proved-cancel-only",try clean(f) && f.helper.client.cancels==2 && f.helper.client.auths==1)
  }catch{a("token-withdrawal-after-ACK-does-not-mark-or-clean",false);a("same-current-owner-after-withdrawal-retries-proved-cancel-only",false)}
  do {
   let f=try await fresh("cancel-consumed-intent"),nonce=try path(f,"promotion-")
   var obj=try JSONSerialization.jsonObject(with:Data(contentsOf:nonce)) as! [String:Any],tx=obj["transaction"] as! [String:Any]
   tx["stageConsentPending"]=false;obj["transaction"]=tx
   var bytes=try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]);bytes.append(10);try bytes.write(to:nonce);precondition(chmod(nonce.path,0o600)==0)
   let bad=await denied(f),m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   a("root-cancel-ACK-cannot-delete-conservative-consumed-send-intent",try bad && Data(contentsOf:nonce)==bytes && f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:m)!.cancelled && f.helper.client.cancels==1 && f.app.profileService.cache.saves==0)
   let retry=await denied(f)
   a("consumed-intent-retry-no-second-RPC-no-admission-or-downgrade",try retry && Data(contentsOf:nonce)==bytes && f.helper.client.cancels==1 && f.helper.client.replacements==0 && f.helper.client.commits==0 && f.helper.client.recoveries==0)
  }catch{a("root-cancel-ACK-cannot-delete-conservative-consumed-send-intent",false);a("consumed-intent-retry-no-second-RPC-no-admission-or-downgrade",false)}
  do {
   let f=try await fresh("cancel-cleanup-after-marker")
   f.helper.client.mode="cancel-private-cleanup-denied";let bad=await denied(f),m=try f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner)!
   let marked=try f.app.nativeProtectedRestartStore.stageConsent(owner:f.app.owner,material:m)!.cancelled
   let nonce=try path(f,"promotion-");precondition(chmod(nonce.path,0o600)==0);f.helper.client.mode=""
   try await f.app.applyNativeProtectedRestart(.cancel,helper:f.helper)
   a("durable-client-marker-private-cleanup-retry-needs-no-second-root-RPC",try bad && marked && clean(f) && f.helper.client.cancels==1)
  }catch{a("durable-client-marker-private-cleanup-retry-needs-no-second-root-RPC",false)}
  do {
   let f=try Fixture("cancel-foreign-process",oldProcess:true)
   let existing=try f.app.nativeProtectedRestartStore.loadCapability(owner:f.app.owner,material:f.app.material)!
   try f.app.nativeProtectedRestartStore.removeCapability(owner:f.app.owner,expected:existing)
   try f.app.nativeProtectedRestartStore.retainStageConsent(owner:f.app.owner,material:f.app.material)
   _=try f.app.nativeProtectedRestartStore.capability(owner:f.app.owner,material:f.app.material,now:UInt64(Date().timeIntervalSince1970),generate:{String(repeating:"ab",count:32)})
   let bad=await denied(f)
   a("foreign-process-cannot-use-original-owner-cancel-path",try bad && f.helper.client.cancels==0 && f.app.nativeProtectedRestartStore.loadMaterial(owner:f.app.owner) != nil && f.app.profileService.cache.saves==0)
  }catch{a("foreign-process-cannot-use-original-owner-cancel-path",false)}
  print("pre_stage_cancel_client_matrix cases=\(cases) failures=\(failures) live_network_commands=0 root_port=inert OS_crash_acceptance=not_claimed")
  exit(failures==0 ? 0:1)
 }
}
'''
HARNESS = H + "\n" + MAIN
if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="pre-stage-cancel-client-", dir=Path(os.environ.get("TMPDIR", "/private/tmp")).resolve()) as raw:
        d = Path(raw); (d / "main.swift").write_text(HARNESS); data = d / "app-data"; data.mkdir(mode=0o700)
        files = [S / "Models/VEXModels.swift"] + [P / n for n in [
            "VPNProfileCache.swift", "NativeAwgBoolean.swift", "NativePSKIdentifier.swift", "NativePushPSKEventQueue.swift", "NativePushSecureFileStore.swift",
            "NativePSKStagedProfileStore.swift", "NativePSKRotationValidation.swift", "NativeVPNProfileAuthorizationVerifier.swift", "NativeAdmittedProfileStore.swift",
            "NativeProtectedReplacementCoordinator.swift", "NativeProtectedPromotionStore.swift", "NativeProtectedRestartStore.swift", "NativeProtectedRestartCoordinator.swift"]]
        built = subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, files), str(d / "main.swift"), "-o", str(d / "probe")], capture_output=True, timeout=180)
        sys.stdout.buffer.write(built.stdout); sys.stderr.buffer.write(built.stderr)
        if built.returncode: raise SystemExit(built.returncode)
        result = subprocess.run(["rtk", "proxy", str(d / "probe"), str(data)], capture_output=True, timeout=180)
        sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)
        names = [line.split(" ")[1].split("=")[0] for line in result.stdout.decode().splitlines() if line.startswith("pre_stage_cancel_client ")]
        if len(names) != 23 or len(set(names)) != 23 or b"pre_stage_cancel_client_matrix cases=23 " not in result.stdout: raise SystemExit(1)
        raise SystemExit(result.returncode)
