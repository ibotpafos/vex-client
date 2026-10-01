#!/usr/bin/env python3
"""Offline URLProtocol contract fixture assembled from exact production Swift bodies."""
from pathlib import Path
import hashlib, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
API=ROOT/'macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift'
MODELS=ROOT/'macos-native/Sources/VEXNativeMac/Models/VEXModels.swift'
REGISTRAR=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushAPIRegistrar.swift'
SERVICE=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushRegistrationService.swift'
def extract(text, marker):
    start=text.index(marker); brace=text.index('{',start); depth=1; i=brace+1
    while depth:
        depth += (text[i]=='{')-(text[i]=='}'); i+=1
    return text[start:i]
a=API.read_text(); m=MODELS.read_text(); registrar_source=REGISTRAR.read_text(); service_source=SERVICE.read_text()
register=extract(a,'    func registerNativePushToken(')
json=extract(a,'    private func json<T: Decodable>(').replace('private func json','func json',1)
error_payload=extract(a,'    private func apiErrorPayload(').replace('private func apiErrorPayload','func apiErrorPayload',1)
response=extract(a,'private struct NativeDeviceRegistrationResponse')
empty=extract(a,'private struct EmptyResponse')
api_error=extract(a,'enum VEXAPIError')
vpn=extract(m,'struct VpnDevice: Codable, Equatable, Identifiable')
request=extract(service_source,'struct NativePushRegistrationRequest: Equatable')
registration_protocol=extract(service_source,'@MainActor\nprotocol NativePushRegistrationRegistrar')
registrar=extract(registrar_source,'@MainActor\nfinal class NativePushAPIRegistrar')
# Source extraction avoids reimplementing production request/json/error/decoder logic.
fixture=f'''import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
struct VEXAppInfo {{ static let version="fixture"; static let buildNumber=1; static let channel="fixture"; static let apiClientVersion="fixture" }}
struct VEXAPIClient {{
 var urlSession: URLSession = .shared
 var baseURL = URL(string: "https://fixture.invalid")!
{register}
{json}
{error_payload}
}}
{response}
{empty}
{api_error}
{vpn}
{request}
{registration_protocol}
{registrar}
final class FixtureProtocol: URLProtocol {{
 static var mode="success"; static var requests:[URLRequest]=[]; static var bodies:[Data]=[]
 static let lock=NSLock(); static var holdsResponse=false
 static let entered=DispatchSemaphore(value:0); static let release=DispatchSemaphore(value:0)
 override class func canInit(with request: URLRequest)->Bool {{ true }}
 override class func canonicalRequest(for request: URLRequest)->URLRequest {{ request }}
 static func reset(_ nextMode:String, hold:Bool=false) {{ lock.lock(); mode=nextMode; holdsResponse=hold; requests=[]; bodies=[]; lock.unlock() }}
 static func snapshot() -> ([URLRequest],[Data]) {{ lock.lock(); defer {{ lock.unlock() }}; return (requests,bodies) }}
 static func awaitEntry() async {{ await withCheckedContinuation {{ continuation in DispatchQueue.global().async {{ entered.wait(); continuation.resume() }} }} }}
 override func startLoading() {{
  Self.lock.lock(); let currentMode=Self.mode; let hold=Self.holdsResponse; Self.requests.append(request)
  if let body=request.httpBody {{ Self.bodies.append(body) }} else if let stream=request.httpBodyStream {{ stream.open(); defer {{ stream.close() }}; var data=Data(); let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:4096); defer {{ buffer.deallocate() }}; while stream.hasBytesAvailable {{ let count=stream.read(buffer,maxLength:4096); if count <= 0 {{ break }}; data.append(buffer,count:count) }}; Self.bodies.append(data) }} else {{ Self.bodies.append(Data()) }}; Self.lock.unlock()
  if hold {{ Self.entered.signal(); Self.release.wait() }}
  let code=currentMode == "unauthorized" ? 401 : (currentMode == "unavailable" ? 503 : 200)
  let body:Data
  if currentMode == "malformed" {{ body=Data("{{}}".utf8) }} else if code == 200 {{ body=Data(#"{{"device":{{"id":"fixture-device","name":"","status":"active","push_provider":"apns","has_push_token":true}}}}"#.utf8) }} else if code == 401 {{ body=Data(#"{{"code":"unauthorized","message":"denied"}}"#.utf8) }} else {{ body=Data(#"{{"code":"maintenance","message":"maintenance"}}"#.utf8) }}
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:body); client?.urlProtocolDidFinishLoading(self)
 }}
 override func stopLoading() {{}}
}}
@main struct Main {{
 static let request=NativePushRegistrationRequest(provider:"apns",token:"00ff10",deviceID:"managed-device",accountID:"fixture-account",accessToken:"fixture-auth",sessionGeneration:7)
 static func apiCall(_ client:VEXAPIClient, mode:String) async -> String {{ FixtureProtocol.reset(mode); do {{ try await client.registerNativePushToken(accessToken:request.accessToken,deviceID:request.deviceID,token:request.token); return "ok" }} catch let e as VEXAPIError {{ switch e {{ case .http(let s,_): return "http-\(s)"; case .technicalWorks:return "technical"; case .invalidResponse:return "invalid" }} }} catch {{ return "other" }} }}
 static func registrarCall(_ registrar:NativePushAPIRegistrar) async -> String {{ do {{ try await registrar.registerNativePush(request); return "ok" }} catch is CancellationError {{ return "cancelled" }} catch {{ return "other" }} }}
 static func main() async {{
  let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[FixtureProtocol.self]
  let client=VEXAPIClient(urlSession:URLSession(configuration:config),baseURL:URL(string:"https://fixture.invalid")!)
  let success=await apiCall(client,mode:"success"); let (requests,bodies)=FixtureProtocol.snapshot(); let r=requests[0]; let obj=try! JSONSerialization.jsonObject(with:bodies[0]) as! [String:String]
  let contract=r.httpMethod=="POST" && r.url!.host=="fixture.invalid" && r.url!.path=="/v1/vpn/push-token" && r.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-auth" && r.value(forHTTPHeaderField:"X-Vex-Platform")=="macos" && obj["provider"]=="apns" && obj["device_id"]=="managed-device" && obj["token"]=="00ff10"
  let unauthorized=await apiCall(client,mode:"unauthorized"); let unavailable=await apiCall(client,mode:"unavailable"); let malformed=await apiCall(client,mode:"malformed")
  let registrar=NativePushAPIRegistrar(api:client); var current=false; registrar.isCurrent={{ _ in current }}; FixtureProtocol.reset("success"); let stalePreentry=await registrarCall(registrar); let preentryNoRequest=FixtureProtocol.snapshot().0.isEmpty
  current=true; FixtureProtocol.reset("success",hold:true); let inFlight=Task {{ await registrarCall(registrar) }}; await FixtureProtocol.awaitEntry(); current=false; FixtureProtocol.release.signal(); let staleAfterAwait=await inFlight.value
  current=true; FixtureProtocol.reset("unauthorized"); let currentUnauthorized=await registrarCall(registrar)
  print("post_contract=\(contract) success_response=\(success == "ok") unauthorized=\(unauthorized == "http-401") unavailable=\(unavailable == "technical") malformed_success_decoding_error=\(malformed == "other") stale_preentry_cancelled=\(stalePreentry == "cancelled") stale_preentry_no_request=\(preentryNoRequest) stale_after_await_cancelled=\(staleAfterAwait == "cancelled") current_401_retained=\(currentUnauthorized == "other") fixture_only=true")
  exit(contract && success=="ok" && unauthorized=="http-401" && unavailable=="technical" && malformed=="other" && stalePreentry=="cancelled" && preentryNoRequest && staleAfterAwait=="cancelled" && currentUnauthorized=="other" ? 0:1)
 }}
}}'''
with tempfile.TemporaryDirectory(prefix='vex-push-api-') as d:
 p=Path(d); (p/'main.swift').write_text(fixture)
 c=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'main.swift'),'-o',str(p/'x')],text=True,capture_output=True)
 print(c.stdout,end=''); print(c.stderr,end='',file=__import__('sys').stderr)
 if c.returncode: raise SystemExit(c.returncode)
 x=subprocess.run([str(p/'x')],text=True,capture_output=True)
 print('api_source_sha256='+hashlib.sha256(API.read_bytes()).hexdigest());print('models_source_sha256='+hashlib.sha256(MODELS.read_bytes()).hexdigest());print('registrar_source_sha256='+hashlib.sha256(REGISTRAR.read_bytes()).hexdigest());print('service_source_sha256='+hashlib.sha256(SERVICE.read_bytes()).hexdigest());print(x.stdout,end='');print(x.stderr,end='',file=__import__('sys').stderr);raise SystemExit(x.returncode)
