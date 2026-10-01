#!/usr/bin/env python3
"""Compile the real authenticated connect boundary with fake continuation gates only."""
from pathlib import Path
import subprocess,sys,tempfile
DEFAULT=Path(__file__).resolve().parents[2]
def extract(s,m):
 a=s.index(m); b=s.index('{',a); d=1; e=b+1
 while d: d+=(s[e]=='{')-(s[e]=='}'); e+=1
 return s[a:e]
def main(argv):
 compile_only='--compile-only' in argv; roots=[x for x in argv if x!='--compile-only']; root=Path(roots[0]) if roots else DEFAULT
 source=(root/'macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift').read_text()
 method=extract(source,'    private func performConnectVPN(').replace('private func performConnectVPN','func performConnectVPN',1)
 if '    private func ensureAuthenticatedSessionCurrent(' in source:
  auth_guard=extract(source,'    private func ensureAuthenticatedSessionCurrent(').replace('private func ensureAuthenticatedSessionCurrent','func ensureAuthenticatedSessionCurrent',1)
  connect_guard=extract(source,'    private func ensureConnectStillDesired(').replace('private func ensureConnectStillDesired','func ensureConnectStillDesired',1)
 else:
  auth_guard='' # Legacy actual caller/guard have no auth helper; no fake rejection logic.
  connect_guard=extract(source,'    private func ensureConnectStillDesired(').replace('private func ensureConnectStillDesired','func ensureConnectStillDesired',1)
  connect_guard+='\nfunc ensureConnectStillDesired(generation:Int, sessionGeneration:Int?, accessToken token:String?, accountID:String?) throws { try ensureConnectStillDesired(generation:generation) }'
 swift='''import Foundation
enum AuthenticatedOperationError: Error { case sessionChanged }
enum NativeLocationSelectionError: Error { case unavailable; var localizedDescription:String { "unavailable" } }
struct Entitlement { var hasPaidAccess: Bool }; struct PreparedTunnel { let locationId:String }; struct Location { let displayName:String }; struct User { let id:String }; struct Session { let user:User; let accessToken:String }; enum VPNState { case disconnected, connected }; struct Status { var state:VPNState = .connected }
@MainActor final class Gate {
 private var entered = false
 private var released = false
 private var pending: CheckedContinuation<Void,Never>?
 private var observers: [CheckedContinuation<Void,Never>] = []
 func wait() async {
  entered = true
  let current=observers; observers=[]; current.forEach { $0.resume() }
  if !released { await withCheckedContinuation { pending=$0 } }
 }
 func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { observers.append($0) } }
 func release() { released=true; pending?.resume(); pending=nil }
}
@MainActor final class VEXHelperModel { var isBusy=false; var status=Status(); var disconnects=0; func interruptWithDisconnect(releaseAntiLeak:Bool) async { disconnects += 1 } }
@MainActor final class API { var reports=0; var waiter:CheckedContinuation<Void,Never>?; func reportVpnConnect(accessToken:String,tunnel:PreparedTunnel) async { reports += 1; waiter?.resume(); waiter=nil }; func waitForReport() async { if reports>0{return}; await withCheckedContinuation {waiter=$0} } }
@MainActor final class Fixture {
 var isVpnBusy=false; var isDeviceBusy=false; var statusMessage:String?; var desiredVpnState:VPNState = .connected; var entitlement:Entitlement?=Entitlement(hasPaidAccess:true); var targetLocationId:String?="x"; var routingMode=0; var activeTunnel:PreparedTunnel?; var selectedLocation:Location?; var antiLeakEnabled=false; var vpnOperationGeneration=1; var api=API(); var authenticatedSessionGeneration=1; var sessionToken:String?="old"; var session:Session? = .init(user: .init(id:"owner"), accessToken:"old"); var accessToken:String? { sessionToken }; var authGate:Gate?; var entitlementGate:Gate?; var profileGate:Gate?; var connectGate:Gate?; var switchSessionDuringAuth=false; var switchSessionDuringEntitlement=false; var switchSessionDuringConnect=false; var profileReturnedToken:String?; var profileError:Error?; var connectError:Error?; var connectCalls=0; var activeResilienceRoute:Int?; var activeResiliencePolicy:Int?
 func authenticatedAccessToken() async -> String? { if let authGate { await authGate.wait() }; if switchSessionDuringAuth { authenticatedSessionGeneration += 1; sessionToken="new"; session = .init(user: .init(id:"new-owner"), accessToken:"new") }; return sessionToken }
 func ensureEntitlementForConnect(accessToken:String) async -> String? { if let entitlementGate { await entitlementGate.wait() }; if switchSessionDuringEntitlement { authenticatedSessionGeneration += 1; sessionToken="new"; session = .init(user: .init(id:"new-owner"), accessToken:"new"); return nil }; return accessToken }
 func submitDiagnostics(reason:String,status:String,helperStatus:Status,samples:[String:String]) async {}
 func resolveProfileForAuthenticatedSession(accessToken:String,locationId:String?,routingMode:Int,forceRefresh:Bool,prevalidatedEntitlement:Entitlement?, writeHelperConfig:Bool = false) async throws -> (PreparedTunnel,String) { if let profileGate { await profileGate.wait() }; if let profileError { throw profileError }; if let profileReturnedToken { sessionToken=profileReturnedToken; session = .init(user:.init(id:"owner"),accessToken:profileReturnedToken) }; return (PreparedTunnel(locationId:locationId ?? "x"),profileReturnedToken ?? accessToken) }
 func connectWithAutopilot(initialTunnel:PreparedTunnel,accessToken:String,helper:VEXHelperModel,generation:Int,sessionGeneration:Int?=nil,accountID:String?=nil) async throws -> PreparedTunnel { try ensureConnectStillDesired(generation:generation, sessionGeneration:sessionGeneration, accessToken:accessToken, accountID:accountID); connectCalls += 1; if let connectGate { await connectGate.wait() }; if switchSessionDuringConnect { authenticatedSessionGeneration += 1; sessionToken="new"; session = .init(user: .init(id:"new-owner"), accessToken:"new"); throw AuthenticatedOperationError.sessionChanged }; if let connectError { throw connectError }; return initialTunnel }
 func clearActiveTunnelRouteState() {}; func connectErrorMessage(_ e:Error)->String { "error" }; func performDisconnectVPN(using:VEXHelperModel,reason:String,generation:Int) async {}
'''+auth_guard+'\n'+connect_guard+'\n'+method+'''\n}
@main struct Probe { @MainActor static func main() async {
 var results:[(String,Bool)] = []
 let h=VEXHelperModel(); let p=Fixture(); p.profileError = AuthenticatedOperationError.sessionChanged
 await p.performConnectVPN(using:h,generation:1)
 results.append(("stale_profile_no_cleanup",h.disconnects==0 && p.activeTunnel==nil))
 let auth=Fixture(); let ah=VEXHelperModel(); let authGate=Gate(); auth.authGate=authGate
 let authPending=Task { await auth.performConnectVPN(using:ah,generation:1) }
 await authGate.waitUntilEntered(); auth.authenticatedSessionGeneration += 1; auth.sessionToken="new"; auth.session = .init(user:.init(id:"replacement"),accessToken:"new"); auth.statusMessage="replacement-ui"; auth.activeTunnel = .init(locationId:"replacement")
 authGate.release(); await authPending.value; await Task { @MainActor in }.value
 results.append(("stale_auth_preserves_replacement",auth.connectCalls==0 && auth.statusMessage == "replacement-ui" && auth.activeTunnel?.locationId == "replacement" && auth.api.reports == 0 && ah.disconnects == 0))
 let connect=Fixture(); let ch=VEXHelperModel(); let connectGate=Gate(); connect.connectGate=connectGate
 let connectPending=Task { await connect.performConnectVPN(using:ch,generation:1) }
 await connectGate.waitUntilEntered(); connect.authenticatedSessionGeneration += 1; connect.sessionToken="new"; connect.session = .init(user:.init(id:"replacement"),accessToken:"new"); connect.statusMessage="replacement-ui"; connect.activeTunnel = .init(locationId:"replacement")
 connectGate.release(); await connectPending.value; await Task { @MainActor in }.value
 results.append(("stale_connector_preserves_replacement",connect.activeTunnel?.locationId == "replacement" && connect.statusMessage == "replacement-ui" && connect.connectCalls == 1 && connect.api.reports == 0 && ch.disconnects==0))
 let ent=Fixture(); let eh=VEXHelperModel(); let entGate=Gate(); ent.entitlementGate=entGate
 let entPending=Task { await ent.performConnectVPN(using:eh,generation:1) }
 await entGate.waitUntilEntered(); ent.authenticatedSessionGeneration += 1; ent.sessionToken="new"; ent.session = .init(user:.init(id:"replacement"),accessToken:"new"); ent.statusMessage="replacement-ui"; ent.activeTunnel = .init(locationId:"replacement")
 entGate.release(); await entPending.value; await Task { @MainActor in }.value
 results.append(("stale_entitlement_preserves_replacement",ent.connectCalls==0 && ent.statusMessage == "replacement-ui" && ent.activeTunnel?.locationId == "replacement" && ent.api.reports == 0 && eh.disconnects == 0))
 let profile=Fixture(); let ph=VEXHelperModel(); let profileGate=Gate(); profile.profileGate=profileGate
 let profilePending=Task { await profile.performConnectVPN(using:ph,generation:1) }
 await profileGate.waitUntilEntered(); profile.authenticatedSessionGeneration += 1; profile.sessionToken="new"; profile.session = .init(user:.init(id:"replacement"),accessToken:"new"); profile.statusMessage="replacement-ui"; profile.activeTunnel = .init(locationId:"replacement")
 profileGate.release(); await profilePending.value; await Task { @MainActor in }.value
 results.append(("stale_profile_result_preserves_replacement",profile.connectCalls==0 && profile.statusMessage == "replacement-ui" && profile.activeTunnel?.locationId == "replacement" && profile.api.reports == 0 && ph.disconnects == 0))
 let valid=Fixture(); await valid.performConnectVPN(using:VEXHelperModel(),generation:1); await valid.api.waitForReport()
 results.append(("valid_connect",valid.activeTunnel?.locationId == "x" && valid.api.reports == 1))
 let refreshed=Fixture(); refreshed.profileReturnedToken="refreshed"; await refreshed.performConnectVPN(using:VEXHelperModel(),generation:1); await refreshed.api.waitForReport()
 results.append(("valid_profile_refresh",refreshed.activeTunnel?.locationId == "x" && refreshed.api.reports == 1 && refreshed.sessionToken == "refreshed"))
 let cancelled=Fixture(); cancelled.vpnOperationGeneration=2; await cancelled.performConnectVPN(using:VEXHelperModel(),generation:1)
 results.append(("valid_cancel_message",cancelled.statusMessage == "Подключение VPN отменено."))
 let failed=Fixture(); failed.profileError = NativeLocationSelectionError.unavailable; await failed.performConnectVPN(using:VEXHelperModel(),generation:1)
 results.append(("valid_error_message",failed.statusMessage == "error"))
 for (key,value) in results { print("\\(key)=\\(value)") }
 exit(results.allSatisfy { $0.1 } ? 0 : 1)
} }
'''
 with tempfile.TemporaryDirectory(prefix='vex-connect-boundary-') as d:
  p=Path(d); (p/'main.swift').write_text(swift); out=p/'probe'
  c=subprocess.run(['swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(out)],text=True,capture_output=True)
  sys.stdout.write(c.stdout); sys.stderr.write(c.stderr)
  if c.returncode:return c.returncode
  if not compile_only:return subprocess.run([str(out)]).returncode
 return 0
if __name__=='__main__': raise SystemExit(main(sys.argv[1:]))
