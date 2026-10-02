#!/usr/bin/env python3
"""Execute real autopilot/guard/recovery bodies; API/profile/prepared connector are fakes.
No helper, installed app, external request, or network configuration is used.
"""
from pathlib import Path
import subprocess, sys, tempfile
ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
s = (ROOT / 'macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift').read_text()
r = (ROOT / 'macos-native/Sources/VEXNativeMac/Services/VpnAdmissionRecovery.swift').read_text()
def extract(text, mark):
    a = text.index(mark); b = a; parens = 0
    while True:
        if text[b] == '(': parens += 1
        elif text[b] == ')': parens -= 1
        elif text[b] == '{' and parens == 0: break
        b += 1
    n = 1; e = b + 1
    while n:
        n += (text[e] == '{') - (text[e] == '}'); e += 1
    return text[a:e]
method = extract(s, '    private func connectWithAutopilot(').replace('private func', 'func', 1)
guard = extract(s, '    private func ensureConnectStillDesired(').replace('private func', 'func', 1)
auth = extract(s, '    private func ensureAuthenticatedSessionCurrent(').replace('private func', 'func', 1) if '    private func ensureAuthenticatedSessionCurrent(' in s else ''
if not auth:
    # Label-only legacy adapters forward into exact original bodies. They do not
    # implement or simulate an auth check that did not exist in the old caller.
    guard += '\n func ensureConnectStillDesired(generation:Int,sessionGeneration:Int?,accessToken:String?,accountID:String?) throws { try ensureConnectStillDesired(generation:generation) }\n'
    method += '\n func connectWithAutopilot(initialTunnel:PreparedTunnel,accessToken:String,helper:VEXHelperModel,generation:Int,sessionGeneration:Int?,accountID:String?) async throws -> PreparedTunnel { try await connectWithAutopilot(initialTunnel:initialTunnel,accessToken:accessToken,helper:helper,generation:generation) }\n'
recovery = extract(r, '    static func retryFreshProfile<T>(')
if 'shouldFailover:' not in recovery:
    recovery += '\n static func retryFreshProfile<T>(shouldFailover:(Error)->Bool,attempt:() async throws -> T,failover:(Error) async throws -> T) async throws -> T { try await retryFreshProfile(attempt:attempt,failover:failover) }\n'
prefix = r'''import Foundation
struct User { var id:String }; struct Session { var user:User; var accessToken:String }
enum Desired { case connected, disconnected }; enum AuthenticatedOperationError:Error {case sessionChanged}
struct Generic:Error {}; struct InvalidConfig:LocalizedError {var errorDescription:String?{"VPN_CONFIG_INVALID"}}
struct Device {var id="device"}; struct PreparedTunnel {var locationId="initial";var endpoint:String?="fixture";var device=Device();var rotationRequired=false}
struct ResiliencePolicy {var marker=1}; struct Status {}; struct Location {var id="failover"}
enum Cause {case other,keyOrProfile}; struct Assessment {var userMessage="assessment";var diagnosticStatus="fixture";var samples:[String:String]=[:];var cause:Cause = .other;var canFailover=true}
@MainActor final class Gate {
 var entered=false;var released=false;var pending:CheckedContinuation<Void,Never>?;var observers:[CheckedContinuation<Void,Never>]=[]
 func wait() async { entered=true;let old=observers;observers=[];old.forEach{$0.resume()};if !released {await withCheckedContinuation {pending=$0}} }
 func waitUntilEntered() async {if entered{return};await withCheckedContinuation {observers.append($0)}}
 func release(){released=true;pending?.resume();pending=nil}
}
@MainActor final class VEXHelperModel {var status=Status()}
@MainActor final class API {unowned let state:H;init(_ s:H){state=s};func resiliencePolicy(accessToken:String) async throws -> ResiliencePolicy {await state.action("policy");if state.policyError {throw Generic()};return .init()}}
@MainActor final class RouteEngine {unowned let state:H;var cached:ResiliencePolicy?;init(_ s:H){state=s};func cache(policy:ResiliencePolicy){state.events.append("cache");cached=policy};func cachedPolicy()->ResiliencePolicy?{cached}}
@MainActor final class Auto {unowned let state:H;init(_ s:H){state=s};func probe(endpoint:String?) async -> String{await state.action("probe");return "probe"};func usage(accessToken:String,deviceId:String) async -> String{await state.action("usage");return "usage"};func healthReasons(status:Status,usage:String)->[String]{[]};func assess(error:Error,healthReasons:[String],status:Status,probe:String)->Assessment{.init()}}
@MainActor final class Profile {unowned let state:H;init(_ s:H){state=s}
 func rotateKey(accessToken:String,currentTunnel:PreparedTunnel,writeHelperConfig:Bool=true,accountID:String?=nil,validateCurrent:@MainActor () throws -> Void = {}) async throws -> PreparedTunnel?{try validateCurrent();await state.action("rotation");try validateCurrent();if state.rotationError{throw Generic()};return state.rotationReturnsNil ? nil : .init(locationId:"rotated")}
 func resolveProfile(accessToken:String,locationId:String,routingMode:String,forceRefresh:Bool,writeHelperConfig:Bool=true,accountID:String?=nil,validateCurrent:@MainActor () throws -> Void = {}) async throws -> PreparedTunnel {try validateCurrent();let kind=locationId=="failover" ? "failover_resolve":"fresh";await state.action(kind);try validateCurrent();if locationId != "failover" && state.freshError {throw Generic()};if locationId=="failover" && state.failoverError {throw Generic()};return .init(locationId:locationId=="failover" ? "failover":"fresh")}
}
@MainActor enum VpnAdmissionRecovery {
'''
state = r'''
}
@MainActor final class H {
 var authenticatedSessionGeneration=1;var desiredVpnState:Desired = .connected;var vpnOperationGeneration=1;var session:Session? = .init(user:.init(id:"owner"),accessToken:"token")
 var events:[String]=[];var gate:Gate?;var target="";var policyError=false;var initialError=true;var invalidInitial=false;var cancelInitial=false;var rotationReturnsNil=false;var rotationError=false;var freshError=false;var freshConnectorError=false;var failoverError=false
 lazy var api=API(self);lazy var dynamicRouteEngine=RouteEngine(self);lazy var autopilotService=Auto(self);lazy var profileService=Profile(self)
 var activeResiliencePolicy:ResiliencePolicy?;var activeResilienceRoute:String?;var statusMessage:String?;var routingMode="full";var allowsAutomaticFailover=true;var selected="initial"
 func action(_ name:String) async {events.append(name);if target==name,let gate {await gate.wait()}}
 func connectPreparedTunnel(_ t:PreparedTunnel,helper:VEXHelperModel,generation:Int,resiliencePolicy:ResiliencePolicy?=nil,sessionGeneration:Int?=nil,accessToken:String?=nil,accountID:String?=nil) async throws -> PreparedTunnel {
  // This is a fake connector, NOT the real prepared/handshake implementation.
  // It uses the actual extracted guards when the real caller supplies context.
  try ensureConnectStillDesired(generation:generation,sessionGeneration:sessionGeneration,accessToken:accessToken,accountID:accountID)
  await action("connector:"+t.locationId)
  try ensureConnectStillDesired(generation:generation,sessionGeneration:sessionGeneration,accessToken:accessToken,accountID:accountID)
  if t.locationId=="initial" {if invalidInitial{throw InvalidConfig()};if cancelInitial{throw CancellationError()};if initialError{throw Generic()}}
  if t.locationId=="fresh" && freshConnectorError {throw Generic()};return t
 }
 func submitDiagnostics(reason:String,status:String,helperStatus:Status,samples:[String:String]) async {await action(reason=="vpn_autopilot_failover" ? "failover_diagnostic":"initial_diagnostic")}
 func bestFailoverLocation(excluding:String)->Location?{.init()}
 func applyManualSelection(locationId:String){events.append("manual_selection");selected=locationId}
'''
main = r'''
}
@main struct Main {@MainActor static func main() async {
 var checks:[Bool]=[];let helper=VEXHelperModel()
 func invoke(_ a:H,_ rotation:Bool=false) async throws -> PreparedTunnel {try await a.connectWithAutopilot(initialTunnel:.init(rotationRequired:rotation),accessToken:"token",helper:helper,generation:1,sessionGeneration:1,accountID:"owner")}
 // Every event counter measures invocation before suspension. Already-dispatched
 // work may complete after invalidation; the test rejects only NEW work/state.
 let cases:[(String,Bool,Bool,Bool)] = [
  ("policy",false,false,false),("policy",true,false,false),
  ("connector:initial",false,false,false),("probe",false,false,false),
  ("usage",false,false,false),("initial_diagnostic",false,false,false),
  ("rotation",false,true,false),("rotation",false,true,true),
  ("fresh",false,false,false),("connector:fresh",false,false,false),
  ("failover_resolve",false,false,false),("failover_diagnostic",false,false,false),
  ("connector:failover",false,false,false)
 ]
 for (stage,policyFailure,rotation,nilRotation) in cases {
  let a=H();let gate=Gate();a.gate=gate;a.target=stage;a.policyError=policyFailure;a.rotationReturnsNil=nilRotation
  if stage=="connector:initial" {a.initialError=false}
  if stage.hasPrefix("failover") || stage=="connector:failover" {a.freshError=true}
  let pending=Task {() -> Bool in do{_ = try await invoke(a,rotation);return false}catch AuthenticatedOperationError.sessionChanged{return true}catch{return false}}
  await gate.waitUntilEntered();let dispatched=a.events
  a.authenticatedSessionGeneration += 1;a.session = .init(user:.init(id:"replacement"),accessToken:"replacement")
  a.statusMessage="replacement-ui";a.activeResiliencePolicy = .init(marker:99);a.activeResilienceRoute="replacement-route";a.dynamicRouteEngine.cached = .init(marker:99);a.selected="replacement"
  gate.release();let rejected=await pending.value
  let preserved=rejected && a.events==dispatched && a.statusMessage=="replacement-ui" && a.activeResiliencePolicy?.marker==99 && a.activeResilienceRoute=="replacement-route" && a.dynamicRouteEngine.cached?.marker==99 && a.selected=="replacement"
  print("stage=\(stage) policy_error=\(policyFailure) rotation_nil=\(nilRotation) rejected=\(rejected) new_actions=\(a.events.count-dispatched.count) preserved=\(preserved)");checks.append(preserved)
 }
 // Same-token re-login, token-only replacement and owner-only replacement must
 // each be enforced by the actual caller context, not by fixture assumptions.
 for dimension in ["generation","token","owner"] {
  let a=H();let gate=Gate();a.target="usage";a.gate=gate
  let pending=Task {() -> Bool in do{_ = try await invoke(a);return false}catch AuthenticatedOperationError.sessionChanged{return true}catch{return false}}
  await gate.waitUntilEntered();let before=a.events
  if dimension=="generation" {a.authenticatedSessionGeneration+=1};if dimension=="token" {a.session?.accessToken="replacement"};if dimension=="owner" {a.session?.user.id="replacement"}
  a.statusMessage="replacement-ui";gate.release();let rejected=await pending.value
  let safe=rejected && before==a.events && a.statusMessage=="replacement-ui";print("dimension=\(dimension) safe=\(safe)");checks.append(safe)
 }
 for kind in ["normal","policy_fallback","fresh","rotation","rotation_nil","fresh_transport_failover","fresh_connector_failover"] {
  let a=H();a.initialError = kind != "normal" && kind != "policy_fallback";a.policyError=kind=="policy_fallback";a.rotationReturnsNil=kind=="rotation_nil";a.freshError=kind=="fresh_transport_failover";a.freshConnectorError=kind=="fresh_connector_failover"
  do {let t=try await invoke(a,kind=="rotation" || kind=="rotation_nil");let expected=kind.hasSuffix("failover") ? "failover":(kind=="rotation" ? "rotated":(a.initialError ? "fresh":"initial"));let okay=t.locationId==expected;print("valid=\(kind) accepted=\(okay)");checks.append(okay)}catch{print("valid=\(kind) error=\(error)");checks.append(false)}
 }
 for kind in ["config","cancel"] {let a=H();a.invalidInitial=kind=="config";a.cancelInitial=kind=="cancel";do{_ = try await invoke(a);checks.append(false);print("terminal=\(kind) no_recovery=false")}catch{let okay=a.events==["policy","cache","connector:initial"];print("terminal=\(kind) no_recovery=\(okay)");checks.append(okay)}}
 // This matrix is actual orchestration + guards/recovery with typed downstream
 // fakes. It is NOT a live OS tunnel, profile API or peer/handshake acceptance.
 exit(checks.allSatisfy{$0} ? 0:1)
}}
'''
fixture = prefix + recovery + state + auth + '\n' + guard + '\n' + method + main
with tempfile.TemporaryDirectory(prefix='vex-autopilot-matrix-') as d:
    p=Path(d);(p/'main.swift').write_text(fixture);cmd=['swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'probe')]
    q=subprocess.run(cmd,capture_output=True,text=True);sys.stdout.write(q.stdout);sys.stderr.write(q.stderr)
    if q.returncode:raise SystemExit(q.returncode)
    raise SystemExit(subprocess.run([str(p/'probe')]).returncode)
