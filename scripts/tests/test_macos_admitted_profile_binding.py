#!/usr/bin/env python3
"""Real connect/admission/store/coordinator bodies; all helper and network ports inert.

Optional source root makes this a frozen baseline/modified/rollback evaluator.
No app, installed helper, network, DNS, Keychain or signing identity is accessed.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
S = ROOT / "macos-native/Sources/VEXNativeMac"
app = (S / "Stores/VEXAppState.swift").read_text()
helper = (S / "VEXHelperClient.swift").read_text()


def extract(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


store = S / "Services/NativeAdmittedProfileStore.swift"
coordinator = S / "Services/NativeProtectedReplacementCoordinator.swift"
# Compatibility ports allow OLD production connect bodies to run, not to gain
# new admission behavior. The old bodies never call record()/verifyAdmittedSource().
legacy_store = """
@MainActor final class NativeAdmittedProfileStore {
 struct Scope:Equatable {let accountID:String;let installationID:String;let sessionGeneration:Int}
 struct Source {let revision=UUID();let tunnel:PreparedTunnel;let canonicalConfig:String;let ownerTokenSHA256:String;let scope:Scope}
 enum Failure:Error {case staleSource}
 var value:Source?;weak var helper:AnyObject?
 @discardableResult func record(tunnel:PreparedTunnel,canonicalConfig:String,ownerTokenSHA256:String,scope:Scope,helper:AnyObject)throws->Source {let v=Source(tunnel:tunnel,canonicalConfig:canonicalConfig,ownerTokenSHA256:ownerTokenSHA256,scope:scope);value=v;self.helper=helper;return v}
 func source(for tunnel:PreparedTunnel,scope:Scope,helper:AnyObject)throws->Source {guard let v=value,v.tunnel==tunnel,v.scope==scope,self.helper === helper else {throw Failure.staleSource};return v}
 func isCurrent(_ source:Source,scope:Scope,helper:AnyObject)->Bool {(try? self.source(for:source.tunnel,scope:scope,helper:helper).revision)==source.revision}
 func clear(){value=nil;helper=nil}
}
"""
remember = extract(app, "    private func rememberNativeAdmittedProfile(") if "    private func rememberNativeAdmittedProfile(" in app else """
 private func rememberNativeAdmittedProfile(_ tunnel:PreparedTunnel,canonicalConfig:String,helper:VEXHelperModel,generation:Int,sessionGeneration:Int?,accessToken:String?,accountID:String?)async {}
"""
scope = extract(app, "    private func nativeAdmittedProfileScope(") if "    private func nativeAdmittedProfileScope(" in app else """
 private func nativeAdmittedProfileScope(for tunnel:PreparedTunnel)throws->NativeAdmittedProfileStore.Scope {.init(accountID:session!.user.id,installationID:nativePushIdentityStore.value!,sessionGeneration:authenticatedSessionGeneration)}
"""
proof = extract(helper, "    func verifyAdmittedSource(") if "    func verifyAdmittedSource(" in helper else """
 func verifyAdmittedSource(_ expectedSHA256:String,isCurrent:@escaping ()->Bool)async throws->String {throw FixtureError.denied}
"""
swift = r'''
import Foundation
import CryptoKit
struct User {let id:String};struct Session {let user:User;let accessToken:String}
enum AuthenticatedOperationError:Error {case sessionChanged}
enum VpnAutopilotRuntimeError:Error {case connectFailed(String)}
enum FixtureError:Error {case denied}
struct Device:Equatable {let id:String="d";var externalDeviceId:String?="installation"}
struct PreparedTunnel:Equatable {
 var locationId="l",endpoint:String?="host:1234",configEndpoint:String?=nil,config="signed-host-config"
 var device=Device()
 func withEndpoint(_ endpoint:String)->PreparedTunnel? {var copy=self;copy.endpoint=endpoint;return copy}
}
@MainActor final class Identity {var value:String?="installation";func existingDeviceId()->String? {value}}
struct ResiliencePolicy {}
struct ResilienceConnectionCandidate {let endpoint:String="host:1234"}
struct Status {var routeOk=false,socketExists=false;var latestHandshake:UInt64?=nil;var rxBytes:UInt64=0}
@MainActor final class LastTunnelEndpointStore {func save(_ endpoint:String,locationId:String) {}}
@MainActor final class Auto {func fallbackTunnels(for tunnel:PreparedTunnel)->[PreparedTunnel] {[tunnel]}}
@MainActor final class Dynamic {
 func orderedCandidates(for:PreparedTunnel,policy:ResiliencePolicy)->[ResilienceConnectionCandidate] {[]}
 func recordSuccess(_:ResilienceConnectionCandidate,policy:ResiliencePolicy) {}
 func recordFailure(_:ResilienceConnectionCandidate,policy:ResiliencePolicy) {}
}
@MainActor final class Client {
 unowned let app:H;var snapshots=0,expectedHashes:[String]=[]
 init(_ app:H) {self.app=app}
 func send(_ command:String,timeoutSeconds:Int)async throws->String {
  precondition(command=="protected-snapshot");snapshots+=1;await Task.yield()
  if app.mode=="denied" || !app.antiLeakEnabled {throw FixtureError.denied}
  if app.mode=="stale-session" {app.authenticatedSessionGeneration+=1}
  if app.mode=="stale-installation" {app.nativePushIdentityStore.value="other"}
  if app.mode=="stale-token" {app.session = .init(user:.init(id:"a"),accessToken:"other")}
  if app.mode=="stale-intent" {app.vpnOperationGeneration+=1}
  let hash=NativeProtectedReplacementCoordinator.digest(app.mode=="wrong-digest" ? "foreign" : "canonical-resolved-bytes")
  let owner=NativeProtectedReplacementCoordinator.digest("owner")
  let pending=app.mode=="journal" ? "true" : "false"
  var result="protected_protocol=1 recovery_pending=\(pending) source_sha256=\(hash) owner_token_sha256=\(owner) transaction_id=E63DCEBD-109A-4C45-A23C-3F32BF42597A\n"
  if app.mode=="duplicate" {result="source_sha256=\(hash) "+result}
  if app.mode=="unterminated" {result.removeLast()}
  return result
 }
}
@MainActor final class VEXHelperModel {
 var status=Status(),canUseExistingValidatedHelper=true,isBusy=false,hasPendingProtectedReplacement=false,lastConnectAdmissionRejected=false
 var message:String?;var ready=0,connects=0,disconnects=0
 unowned let app:H;let client:Client;private let protectedReplacement=NativeProtectedReplacementCoordinator()
 init(_ app:H) {self.app=app;client=Client(app)}
 func ensureHelperReady()async throws {ready+=1}
 func connect(antiLeakEnabled:Bool)async {connects+=1;lastConnectAdmissionRejected=app.mode=="rejected"}
 func disconnect(releaseAntiLeak:Bool)async->Bool {disconnects+=1;return true}
 PROOF
}
@MainActor final class Profile {
 var writes=0
 func writeHelperConfig(for:PreparedTunnel,validateCurrent:@MainActor ()throws->Void)async throws->String {try validateCurrent();writes+=1;await Task.yield();try validateCurrent();return "canonical-resolved-bytes"}
}
@MainActor final class H {
 // No protected-source restore in these legacy fixtures; durable replay fences have their own actual-store matrix.
 var hasNativeProtectedSourceRestorationFence=false
 var nativeProtectedRestorationAdmissionGeneration:Int?
 func completeNativeProtectedSourceRestoration(isCurrent:()->Bool) throws {}
 enum Desired {case connected,disconnected}
 var desiredVpnState:Desired = .connected,vpnOperationGeneration=1,authenticatedSessionGeneration=1
 var session:Session? = .init(user:.init(id:"a"),accessToken:"t")
 let nativePushIdentityStore=Identity(),nativeAdmittedProfiles=NativeAdmittedProfileStore(),profileService=Profile(),autopilotService=Auto(),dynamicRouteEngine=Dynamic()
 var antiLeakEnabled=true,mode="valid",handshakes=0,handshake=true
 var activeResilienceRoute:ResilienceConnectionCandidate?
 AUTH
 GUARD
 SCOPE
 REMEMBER
 CONNECT
 func scopeForFixture(_ tunnel:PreparedTunnel)throws->NativeAdmittedProfileStore.Scope {try nativeAdmittedProfileScope(for:tunnel)}
 func verifiedHandshake(for:PreparedTunnel,helper:VEXHelperModel,previousStatus:Status,startedAt:Date,generation:Int,sessionGeneration:Int?=nil,accessToken:String?=nil,accountID:String?=nil)async throws->Bool {handshakes+=1;return handshake}
 func dynamicRouteTransport(_:ResilienceConnectionCandidate)->String {"fixture"}
 func submitRouteDiagnostics(connectionEvent:String,transportFrom:String?,transportTo:String?,status:String,helperStatus:Status?,sessionGeneration:Int?=nil,accessToken:String?=nil,accountID:String?=nil) {}
 func run(_ tunnel:PreparedTunnel,_ helper:VEXHelperModel)async throws->PreparedTunnel {try await connectPreparedTunnel(tunnel,helper:helper,generation:1,sessionGeneration:1,accessToken:"t",accountID:"a")}
}
@main struct Main {
 @MainActor static func main()async {
  var cases=0,failures=0
  func check(_ name:String,_ passed:Bool) {cases+=1;if !passed {failures+=1};print("admitted_source \(name)=\(passed ? "PASS" : "FAIL")")}
  do {
   let a=H(),t=PreparedTunnel();let h=VEXHelperModel(a);_=try await a.run(t,h)
   let source=try a.nativeAdmittedProfiles.source(for:t,scope:try a.scopeForFixture(t),helper:h)
   check("connect-retains-written-canonical-bytes-after-handshake",source.canonicalConfig=="canonical-resolved-bytes" && source.canonicalConfig != t.config && source.ownerTokenSHA256==NativeProtectedReplacementCoordinator.digest("owner") && a.handshakes==1 && h.client.snapshots==1 && h.disconnects==0)
   for change in ["account","installation","session","profile","helper"] {
    var query=t;var scope=try a.scopeForFixture(t);var peer=h
    switch change {
    case "account":scope = .init(accountID:"other",installationID:scope.installationID,sessionGeneration:scope.sessionGeneration)
    case "installation":scope = .init(accountID:scope.accountID,installationID:"other",sessionGeneration:scope.sessionGeneration)
    case "session":scope = .init(accountID:scope.accountID,installationID:scope.installationID,sessionGeneration:2)
    case "profile":query.config="different"
    default:peer=VEXHelperModel(a)
    }
    check("source-scope-\(change)",(try? a.nativeAdmittedProfiles.source(for:query,scope:scope,helper:peer))==nil)
   }
   let scope=try a.scopeForFixture(t)
   let next=try a.nativeAdmittedProfiles.record(tunnel:t,canonicalConfig:"other",ownerTokenSHA256:source.ownerTokenSHA256,scope:scope,helper:h)
   check("revision-rebind-fences-old",!a.nativeAdmittedProfiles.isCurrent(source,scope:scope,helper:h) && a.nativeAdmittedProfiles.isCurrent(next,scope:scope,helper:h))
   a.nativeAdmittedProfiles.clear();check("clear-fences-source",!a.nativeAdmittedProfiles.isCurrent(next,scope:scope,helper:h))
  }catch {check("connect-retains-written-canonical-bytes-after-handshake",false)}
  for mode in ["wrong-digest","denied","journal","duplicate","unterminated","anti-leak-off","stale-session","stale-installation","stale-token","stale-intent"] {
   let a=H(),t=PreparedTunnel();a.mode=mode;a.antiLeakEnabled=mode != "anti-leak-off";let h=VEXHelperModel(a)
   var returned=false;do {_=try await a.run(t,h);returned=true}catch {}
   let scope=NativeAdmittedProfileStore.Scope(accountID:"a",installationID:"installation",sessionGeneration:1)
   let rejected=(try? a.nativeAdmittedProfiles.source(for:t,scope:scope,helper:h))==nil
   check("proof-\(mode)-no-adoption-no-disconnect",rejected && h.disconnects==0 && h.connects==1 && (mode.hasPrefix("stale-") ? true : returned))
  }
  do {
   let a=H(),t=PreparedTunnel();a.handshake=false;let h=VEXHelperModel(a);_=try? await a.run(t,h)
   check("no-proof-before-verified-handshake",h.client.snapshots==0 && (try? a.nativeAdmittedProfiles.source(for:t,scope:try a.scopeForFixture(t),helper:h))==nil)
  }
  do {
   let a=H(),t=PreparedTunnel();a.mode="rejected";let h=VEXHelperModel(a);_=try? await a.run(t,h)
   check("rejected-admission-never-binds",a.handshakes==0 && h.client.snapshots==0 && h.disconnects==0)
  }
  for invalid in ["empty-config","oversized-config","invalid-owner","empty-account","negative-session"] {
   let store=NativeAdmittedProfileStore(),a=H(),t=PreparedTunnel();let h=VEXHelperModel(a)
   let config=invalid=="empty-config" ? "" : (invalid=="oversized-config" ? String(repeating:"a",count:262145) : "bytes")
   let owner=invalid=="invalid-owner" ? String(repeating:"A",count:64) : NativeProtectedReplacementCoordinator.digest("owner")
   let scope=NativeAdmittedProfileStore.Scope(accountID:invalid=="empty-account" ? "" : "a",installationID:"installation",sessionGeneration:invalid=="negative-session" ? -1 : 1)
   do {_=try store.record(tunnel:t,canonicalConfig:config,ownerTokenSHA256:owner,scope:scope,helper:h);check("record-\(invalid)",false)}catch {check("record-\(invalid)",true)}
  }
  print("admitted_source_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
  exit(failures==0 ? 0 : 1)
 }
}
'''
for name, body in {
    "PROOF": proof, "REMEMBER": remember, "SCOPE": scope,
    "AUTH": extract(app, "    private func ensureAuthenticatedSessionCurrent("),
    "GUARD": extract(app, "    private func ensureConnectStillDesired("),
    "CONNECT": extract(app, "    private func connectPreparedTunnel("),
}.items():
    swift = swift.replace(name, body)
if not store.exists():
    swift += legacy_store
scratch = Path(os.environ.get("TMPDIR", "/tmp")).resolve()
with tempfile.TemporaryDirectory(prefix="admitted-source-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(swift)
    result = subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", "-parse-as-library",
                             str(coordinator), *([str(store)] if store.exists() else []),
                             str(directory / "main.swift"), "-o", str(directory / "probe")], timeout=180)
    if result.returncode:
        raise SystemExit(result.returncode)
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe")], timeout=60).returncode)
