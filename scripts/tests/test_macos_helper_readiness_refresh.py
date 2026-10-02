#!/usr/bin/env python3
"""Compile actual helper readiness/read bodies against inert transport-only ports."""
from pathlib import Path
import os, subprocess, sys, tempfile
ROOT=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
source=(ROOT/"macos-native/Sources/VEXNativeMac/VEXHelperClient.swift").read_text()
def body(sig):
 a=source.index(sig); b=source.index("{",a); n=1; i=b+1
 while n: n+=(source[i]=="{")-(source[i]=="}"); i+=1
 return source[a:i]
has_readiness="    var canUseExistingValidatedHelper: Bool" in source
has_bool_refresh="    func refreshStatus(quiet: Bool = false) async -> Bool" in source
readiness=body("    var canUseExistingValidatedHelper: Bool") if has_readiness else "var canUseExistingValidatedHelper: Bool { false }"
refresh=body("    func refreshStatus(quiet: Bool = false) async -> Bool") if has_bool_refresh else "func refreshStatus(quiet: Bool = false) async -> Bool { false }"
swift=r'''
import Foundation
enum State { case connected, disconnected }
struct VpnStatus: Equatable { var state:State; var hasManagedNetworkState:Bool; init(state:State,hasManagedNetworkState:Bool) { self.state=state; self.hasManagedNetworkState=hasManagedNetworkState }; static let disconnected = VpnStatus(state: .disconnected,hasManagedNetworkState: false); init(helperResponse:Response){ if helperResponse.kind == "good" { self=VpnStatus(state: .connected,hasManagedNetworkState: true) } else { self=VpnStatus.disconnected } } }
struct Response { let kind:String }
enum PortError:Error { case failed }
@MainActor final class Client { var next: Result<Response,Error> = .success(Response(kind:"good")); var sends=0; func sendStatus() async throws->Response { sends+=1; return try next.get() } }
struct VEXHelperInstallState { let filesCurrent:Bool; let socketConnectable:Bool }
enum HelperDisconnectConfirmation { static func isExplicitlyDisconnected(_ response:Response)->Bool { response.kind=="down" } }
@MainActor final class H {
 var status=VpnStatus.disconnected; var message:String?; var installState:VEXHelperInstallState?; var hasConfirmedIdleStatus=false; var client=Client(); var consecutiveStatusFailures=0; var helperReadinessValidated=false; var installerCalls=0,connectCalls=0,downCalls=0
 READINESS
 REFRESH
}
@main struct Main { @MainActor static func main() async {
 let h=H(); let noForeground = !h.canUseExistingValidatedHelper
 h.helperReadinessValidated=true; h.installState=VEXHelperInstallState(filesCurrent:true,socketConnectable:false); let noSocket = !h.canUseExistingValidatedHelper
 h.installState=VEXHelperInstallState(filesCurrent:false,socketConnectable:true); let noFiles = !h.canUseExistingValidatedHelper
 h.installState=VEXHelperInstallState(filesCurrent:true,socketConnectable:true); let ready=h.canUseExistingValidatedHelper
 let good=await h.refreshStatus(quiet:true); let goodUsable=good && h.status.state == .connected && h.status.hasManagedNetworkState
 h.client.next = .failure(PortError.failed); let first=await h.refreshStatus(quiet:true); let retainedOne = !first && h.status.state == .connected && h.status.hasManagedNetworkState
 let second=await h.refreshStatus(quiet:true); let retainedTwo = !second && h.status.state == .connected && h.status.hasManagedNetworkState
 let third=await h.refreshStatus(quiet:true); let disconnected = !third && h.status == .disconnected
 h.client.next = .success(Response(kind:"malformed")); let malformed=await h.refreshStatus(quiet:true); let malformedUnusable=malformed && !h.status.hasManagedNetworkState
 let noMutation=h.installerCalls==0 && h.connectCalls==0 && h.downCalls==0
 let all=noForeground && noSocket && noFiles && ready && goodUsable && retainedOne && retainedTwo && disconnected && malformedUnusable && noMutation
 print("helper_readiness_refresh bool_capability=BOOL_CAPABILITY readiness=\(noForeground && noSocket && noFiles && ready) good=\(goodUsable) retained_failures=\(retainedOne && retainedTwo) third_disconnected=\(disconnected) malformed_transport_only=\(malformedUnusable) no_mutation=\(noMutation)")
 exit(BOOL_CAPABILITY ? (all ? 0:1) : 1)
} }
'''.replace("READINESS",readiness).replace("REFRESH",refresh).replace("BOOL_CAPABILITY","true" if has_readiness and has_bool_refresh else "false")
tmp=Path("/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-25-tests/tmp");tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix="helper-readiness-",dir=tmp) as raw:
 d=Path(raw);(d/"main.swift").write_text(swift)
 subprocess.run(["rtk","proxy","swiftc","-swift-version","5","-parse-as-library",str(d/"main.swift"),"-o",str(d/"probe")],check=True)
 raise SystemExit(subprocess.run(["rtk","proxy",str(d/"probe")]).returncode)
