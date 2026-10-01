#!/usr/bin/env python3
"""Offline extracted-runtime regression for macOS handshake auth invalidation."""
from pathlib import Path
import hashlib, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parents[2]
source=Path(sys.argv[1]) if len(sys.argv)==2 else ROOT/'macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift'
source=source/'macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift' if source.is_dir() else source
text=source.read_text()
def extract(marker):
 start=text.index(marker); brace=text.index('{',start); depth=1; cursor=brace+1
 while depth:
  depth+=(text[cursor]=='{')-(text[cursor]=='}'); cursor+=1
 return text[start:cursor]
handshake=extract('    private func verifiedHandshake(').replace('private func verifiedHandshake','func verifiedHandshake',1)
auth=extract('    private func ensureAuthenticatedSessionCurrent(').replace('private func ensureAuthenticatedSessionCurrent','func ensureAuthenticatedSessionCurrent',1) if '    private func ensureAuthenticatedSessionCurrent(' in text else ''
desired=extract('    private func ensureConnectStillDesired(').replace('private func ensureConnectStillDesired','func ensureConnectStillDesired',1)
current='sessionGeneration: Int? = nil' in handshake
call='try await verifiedHandshake(for: tunnel, helper: helper, previousStatus: previous, startedAt: Date(), generation: 1, sessionGeneration: 1, accessToken: "token", accountID: "owner")' if current else 'try await verifiedHandshake(for: tunnel, helper: helper, previousStatus: previous, startedAt: Date(), generation: 1)'
swift="""import Foundation
enum AuthenticatedOperationError: Error { case sessionChanged }
struct PreparedTunnel {}
struct Status { var matches = false; var latestHandshake: UInt64? = nil }; typealias VEXHelperModel = Helper; typealias VpnStatus = Status
@MainActor final class Helper { var status=Status();var refreshes=0;var entered=false;private var release:CheckedContinuation<Void,Never>?;func refreshStatus(quiet:Bool)async{refreshes+=1;entered=true;await withCheckedContinuation{release=$0}};func releaseFresh(){status.matches=true;status.latestHandshake=UInt64(Date().timeIntervalSince1970)+1;release?.resume();release=nil} }
@MainActor final class Fixture { enum Desired {case connected,disconnected};var desiredVpnState: Desired = .connected;var vpnOperationGeneration=1;var authenticatedSessionGeneration=1;struct User{let id:String};struct Session{let user:User;let accessToken:String};var session: Session? = .init(user:.init(id:"owner"),accessToken:"token");func tunnel(_ tunnel:PreparedTunnel,matches status:Status)->Bool{status.matches}
%s
%s
%s
func invoke(_ helper:Helper,previous:Status)async throws->Bool{let tunnel=PreparedTunnel();return %s}
}
@main struct Main {@MainActor static func run(_ mutation:String?)async->String{let fixture=Fixture();let helper=Helper();let previous=Status();if mutation=="preentry"{fixture.authenticatedSessionGeneration+=1};let task=Task{()->String in do{return try await fixture.invoke(helper,previous:previous) ? "success":"false"}catch AuthenticatedOperationError.sessionChanged{return "auth"}catch is CancellationError{return "cancel"}catch{return "error"}};try? await Task.sleep(nanoseconds:450_000_000);if mutation=="generation"{fixture.authenticatedSessionGeneration+=1};if mutation=="token"{fixture.session = .init(user:.init(id:"owner"),accessToken:"next")};if mutation=="owner"{fixture.session = .init(user:.init(id:"next"),accessToken:"token")};if mutation=="cancel"{fixture.vpnOperationGeneration+=1};helper.releaseFresh();let outcome=await task.value;return "\\(mutation ?? "normal")=\\(outcome),refreshes=\\(helper.refreshes),entered=\\(helper.entered)"}
@MainActor static func main()async{let normal=await run(nil);let generation=await run("generation");let token=await run("token");let owner=await run("owner");let cancel=await run("cancel");let preentry=await run("preentry");print("source_mode=%s source_sha256=%s");print(normal);print(generation);print(token);print(owner);print(cancel);print(preentry);let authOK=[generation,token,owner,preentry].allSatisfy{$0.contains("=auth,")};let normalOK=normal.contains("=success,") && normal.contains("refreshes=1");let cancelOK=cancel.contains("=cancel,");print("normal_success=\\(normalOK) auth_generation_token_owner_preentry_rejected=\\(authOK) cancellation_compatible=\\(cancelOK)");exit(normalOK && authOK && cancelOK ? 0:1)}}
"""%(auth,desired,handshake,call,'current' if current else 'baseline',hashlib.sha256(source.read_bytes()).hexdigest())
with tempfile.TemporaryDirectory(prefix='vex-handshake-auth-') as d:
 p=Path(d); (p/'main.swift').write_text(swift)
 build=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'main.swift'),'-o',str(p/'handshake')],text=True,capture_output=True)
 print(build.stdout,end='');print(build.stderr,end='',file=sys.stderr)
 if build.returncode: raise SystemExit(build.returncode)
 run=subprocess.run([str(p/'handshake')],text=True,capture_output=True)
 print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr);raise SystemExit(run.returncode)
