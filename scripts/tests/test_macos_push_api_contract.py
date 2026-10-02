#!/usr/bin/env python3
"""Offline URLProtocol contract fixture assembled from exact production Swift bodies."""
from pathlib import Path
import hashlib, subprocess, tempfile, sys
ROOT=Path(__file__).resolve().parents[2]
API=ROOT/'macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift'
MODELS=ROOT/'macos-native/Sources/VEXNativeMac/Models/VEXModels.swift'
REGISTRAR=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushAPIRegistrar.swift'
SERVICE=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushRegistrationService.swift'
IDENTIFIER=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift'
if len(sys.argv) == 3 and sys.argv[1] == '--source-root':
 ROOT=Path(sys.argv[2]).resolve(); API=ROOT/'macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift'; MODELS=ROOT/'macos-native/Sources/VEXNativeMac/Models/VEXModels.swift'; REGISTRAR=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushAPIRegistrar.swift'; SERVICE=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePushRegistrationService.swift'; IDENTIFIER=ROOT/'macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift'
def extract(text, marker):
    start=text.index(marker); brace=text.index('{',start); depth=1; i=brace+1
    while depth:
        depth += (text[i]=='{')-(text[i]=='}'); i+=1
    return text[start:i]
a=API.read_text(); m=MODELS.read_text(); registrar_source=REGISTRAR.read_text(); service_source=SERVICE.read_text(); identifier_source=IDENTIFIER.read_text()
register=extract(a,'    func registerNativePushToken(')
unregister=extract(a,'    func unregisterNativePushToken(')
canonical=extract(a,'    private static func isCanonicalAPNsToken(').replace('private static func','static func',1)
json=extract(a,'    private func json<T: Decodable>(').replace('private func json','func json',1)
error_payload=extract(a,'    private func apiErrorPayload(').replace('private func apiErrorPayload','func apiErrorPayload',1)
receipt=extract(a,'struct NativePushRegistrationReceipt')
response=extract(a,'private struct NativeDeviceRegistrationResponse')
push_response=extract(a,'private struct NativePushTokenRegistrationResponse')
clear_response=extract(a,'private struct NativePushTokenClearResponse')
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
{unregister}
{canonical}
{json}
{error_payload}
}}
{receipt}
{response}
{push_response}
{clear_response}
{empty}
{identifier_source.replace('import Foundation','')}
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
  if currentMode == "malformed" {{ body=Data("{{}}".utf8) }} else if currentMode == "zero" {{ body=Data(#"{{"registration_revision":0}}"#.utf8) }} else if currentMode == "negative" {{ body=Data(#"{{"registration_revision":-1}}"#.utf8) }} else if currentMode == "overflow" {{ body=Data(#"{{"registration_revision":9223372036854775808}}"#.utf8) }} else if currentMode == "max" {{ body=Data(#"{{"registration_revision":9223372036854775807}}"#.utf8) }} else if code == 200 && request.httpMethod == "DELETE" {{ body=Data(#"{{"cleared":true}}"#.utf8) }} else if code == 200 {{ body=Data(#"{{"registration_revision":42,"device":{{"id":"fixture-device","name":"","status":"active","push_provider":"apns","has_push_token":true}}}}"#.utf8) }} else if code == 401 {{ body=Data(#"{{"code":"unauthorized","message":"denied"}}"#.utf8) }} else {{ body=Data(#"{{"code":"maintenance","message":"maintenance"}}"#.utf8) }}
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:body); client?.urlProtocolDidFinishLoading(self)
 }}
 override func stopLoading() {{}}
}}
@main struct Main {{
 static let request=NativePushRegistrationRequest(provider:"apns",token:String(repeating:"ab",count:32),deviceID:"vex_0123456789abcdef0123456789abcdef",accountID:"fixture-account",accessToken:"fixture-auth",sessionGeneration:7)
 static func apiCall(_ client:VEXAPIClient, mode:String) async -> String {{ FixtureProtocol.reset(mode); do {{ _ = try await client.registerNativePushToken(accessToken:request.accessToken,deviceID:request.deviceID,token:request.token); return "ok" }} catch let e as VEXAPIError {{ switch e {{ case .http(let s,_): return "http-\(s)"; case .technicalWorks:return "technical"; case .invalidResponse:return "invalid"; case .invalidRequest:return "invalid-request" }} }} catch is DecodingError {{ return "decoding-error" }} catch {{ return "other" }} }}
 static func deleteCall(_ client:VEXAPIClient, mode:String, deviceID:String=request.deviceID, token:String=request.token, revision:Int64=42) async -> String {{ FixtureProtocol.reset(mode); do {{ try await client.unregisterNativePushToken(accessToken:request.accessToken,deviceID:deviceID,token:token,registrationRevision:revision); return "ok" }} catch let e as VEXAPIError {{ switch e {{ case .http(let s,_): return "http-\(s)"; case .technicalWorks:return "technical"; case .invalidResponse:return "invalid"; case .invalidRequest:return "invalid-request" }} }} catch {{ return "other" }} }}
 static func registrarCall(_ registrar:NativePushAPIRegistrar) async -> String {{ do {{ _ = try await registrar.registerNativePush(request); return "ok" }} catch is CancellationError {{ return "cancelled" }} catch let e as VEXAPIError {{ if case .http(let status, _) = e {{ return "http-\(status)" }}; return "unexpected-api-error" }} catch {{ return "other" }} }}
 static func main() async {{
  let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[FixtureProtocol.self]
  let client=VEXAPIClient(urlSession:URLSession(configuration:config),baseURL:URL(string:"https://fixture.invalid")!)
  let success=await apiCall(client,mode:"success"); let (requests,bodies)=FixtureProtocol.snapshot(); let r=requests[0]; let obj=try! JSONSerialization.jsonObject(with:bodies[0]) as! [String:String]
  let contract=r.httpMethod=="POST" && r.url!.host=="fixture.invalid" && r.url!.path=="/v1/vpn/push-token" && r.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-auth" && r.value(forHTTPHeaderField:"X-Vex-Platform")=="macos" && obj["provider"]=="apns" && obj["device_id"]==request.deviceID && obj["token"]==request.token
  let unauthorized=await apiCall(client,mode:"unauthorized"); let unavailable=await apiCall(client,mode:"unavailable"); let malformed=await apiCall(client,mode:"malformed"); let zero=await apiCall(client,mode:"zero"); let negative=await apiCall(client,mode:"negative"); let overflow=await apiCall(client,mode:"overflow"); let maxReceipt=await apiCall(client,mode:"max")
  let deleted=await deleteCall(client,mode:"success"); let (deleteRequests,deleteBodies)=FixtureProtocol.snapshot(); let deleteRequest=deleteRequests[0]; let deleteObject=try! JSONSerialization.jsonObject(with:deleteBodies[0]) as! [String:Any]
  let deleteContract=deleteRequest.httpMethod=="DELETE" && deleteRequest.url!.path=="/v1/vpn/push-token" && deleteRequest.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-auth" && (deleteObject["device_id"] as? String)==request.deviceID && (deleteObject["provider"] as? String)=="apns" && (deleteObject["token"] as? String)==request.token && (deleteObject["registration_revision"] as? Int)==42
  let delete401=await deleteCall(client,mode:"unauthorized"); let invalidID=await deleteCall(client,mode:"success",deviceID:"not-a-server-device"); let invalidToken=await deleteCall(client,mode:"success",token:"AB"); let invalidRevisionZero=await deleteCall(client,mode:"success",revision:0); let zeroNoHTTP=FixtureProtocol.snapshot().0.isEmpty; let invalidRevisionNegative=await deleteCall(client,mode:"success",revision:-1); let negativeNoHTTP=FixtureProtocol.snapshot().0.isEmpty; let maxDelete=await deleteCall(client,mode:"success",revision:Int64.max); let maxDeleteBody=FixtureProtocol.snapshot().1[0]; let maxDeleteExact=(try! JSONSerialization.jsonObject(with:maxDeleteBody) as! [String:Any])["registration_revision"] as? Int64 == Int64.max
  let registrar=NativePushAPIRegistrar(api:client); var current=false; registrar.isCurrent={{ _ in current }}; FixtureProtocol.reset("success"); let stalePreentry=await registrarCall(registrar); let preentryNoRequest=FixtureProtocol.snapshot().0.isEmpty
  current=true; FixtureProtocol.reset("success",hold:true); let inFlight=Task {{ await registrarCall(registrar) }}; await FixtureProtocol.awaitEntry(); current=false; FixtureProtocol.release.signal(); let staleAfterAwait=await inFlight.value
  current=true; FixtureProtocol.reset("unauthorized"); let currentUnauthorized=await registrarCall(registrar)
  print("post_contract=\(contract) delete_contract=\(deleteContract && deleted=="ok") delete_401=\(delete401=="http-401") delete_invalid_id=\(invalidID=="invalid-request") delete_invalid_token=\(invalidToken=="invalid-request") delete_zero_no_http=\(invalidRevisionZero=="invalid-request" && zeroNoHTTP) delete_negative_no_http=\(invalidRevisionNegative=="invalid-request" && negativeNoHTTP) max_revision=\(maxReceipt=="ok" && maxDelete=="ok" && maxDeleteExact) success_response=\(success == "ok") unauthorized=\(unauthorized == "http-401") unavailable=\(unavailable == "technical") malformed_success_decoding_error=\(malformed == "decoding-error") receipt_missing_rejected=\(malformed == "decoding-error") receipt_zero_rejected=\(zero == "invalid") receipt_negative_rejected=\(negative == "invalid") receipt_overflow_rejected=\(overflow == "decoding-error") stale_preentry_cancelled=\(stalePreentry == "cancelled") stale_preentry_no_request=\(preentryNoRequest) stale_after_await_receipt=\(staleAfterAwait == "ok") current_401_retained=\(currentUnauthorized == "http-401") fixture_only=true")
  exit(contract && deleteContract && deleted=="ok" && delete401=="http-401" && invalidID=="invalid-request" && invalidToken=="invalid-request" && success=="ok" && unauthorized=="http-401" && unavailable=="technical" && malformed=="decoding-error" && zero=="invalid" && negative=="invalid" && overflow=="decoding-error" && maxReceipt=="ok" && invalidRevisionZero=="invalid-request" && zeroNoHTTP && invalidRevisionNegative=="invalid-request" && negativeNoHTTP && maxDelete=="ok" && maxDeleteExact && stalePreentry=="cancelled" && preentryNoRequest && staleAfterAwait=="ok" && currentUnauthorized=="http-401" ? 0:1)
 }}
}}'''
with tempfile.TemporaryDirectory(prefix='vex-push-api-') as d:
 p=Path(d); (p/'main.swift').write_text(fixture)
 c=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'main.swift'),'-o',str(p/'x')],text=True,capture_output=True)
 print(c.stdout,end=''); print(c.stderr,end='',file=__import__('sys').stderr)
 if c.returncode: raise SystemExit(c.returncode)
 x=subprocess.run([str(p/'x')],text=True,capture_output=True)
 print('api_source_sha256='+hashlib.sha256(API.read_bytes()).hexdigest());print('models_source_sha256='+hashlib.sha256(MODELS.read_bytes()).hexdigest());print('registrar_source_sha256='+hashlib.sha256(REGISTRAR.read_bytes()).hexdigest());print('service_source_sha256='+hashlib.sha256(SERVICE.read_bytes()).hexdigest());print(x.stdout,end='');print(x.stderr,end='',file=__import__('sys').stderr);raise SystemExit(x.returncode)
