#!/usr/bin/env python3
"""Strictly offline integrated signed PSK stage/cutover runtime proof."""
import argparse, os, pathlib, subprocess, tempfile, textwrap, sys
parser=argparse.ArgumentParser(); parser.add_argument("source_root", nargs="?"); parser.add_argument("--fixture"); parser.add_argument("--routing-mode", default="full_tunnel"); parser.add_argument("--bypass-region"); args=parser.parse_args()

ROOT=pathlib.Path(args.source_root) if args.source_root else pathlib.Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac'
GO=r'''package main
import("crypto/ecdsa";"crypto/elliptic";"crypto/rand";"crypto/sha256";"crypto/x509";"encoding/base64";"encoding/json";"fmt";"os";"time")
type AWG struct { JC int `json:"jc"`; PersistentKeepalive string `json:"persistent_keepalive"` }
type Profile struct { Version int `json:"version"`; Device string `json:"device_id"`; Protocol string `json:"protocol"`; Server string `json:"server"`; Port int `json:"port"`; ServerKey string `json:"server_public_key"`; PSK string `json:"preshared_key"`; IPv4 string `json:"assigned_ipv4"`; DNS []string `json:"dns"`; Allowed []string `json:"allowed_ips"`; AWG *AWG `json:"amnezia,omitempty"` }
func main(){ now:=time.Now().UTC().Truncate(time.Second); k,_:=ecdsa.GenerateKey(elliptic.P256(),rand.Reader); p:=Profile{2,"11111111-1111-4111-8111-111111111111","amneziawg","vpn.example",51820,"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","10.0.0.2/32",[]string{"1.1.1.1"},[]string{"0.0.0.0/0"},&AWG{7,"25"}}; stable,_:=json.Marshal(p); d:=sha256.Sum256(stable); policy:=struct {Schema string `json:"schema"`; User string `json:"user_id"`; Device string `json:"device_id"`; Loc string `json:"assigned_location_id"`; Version int `json:"profile_version"`; Issued time.Time `json:"issued_at"`; Expires time.Time `json:"expires_at"`; Tunnel any `json:"tunnel"`}{"vex.native-vpn-profile.v1","owner",p.Device,"loc",2,now,now.Add(time.Hour),struct {Protocol string `json:"protocol"`; Endpoint string `json:"endpoint"`; IPv4 string `json:"assigned_ipv4"`; ServerKey string `json:"server_public_key"`; PSK string `json:"preshared_key"`; DNS []string `json:"dns"`; Allowed []string `json:"allowed_ips"`; MTU int `json:"mtu"`; Keep int `json:"persistent_keepalive"`; AWG *AWG `json:"amnezia"`}{p.Protocol,"vpn.example:51820",p.IPv4,p.ServerKey,p.PSK,p.DNS,p.Allowed,1280,25,p.AWG}}; raw,_:=json.Marshal(policy); h:=sha256.Sum256(raw); sig,_:=ecdsa.SignASN1(rand.Reader,k,h[:]); der,_:=x509.MarshalPKIXPublicKey(&k.PublicKey); out:=map[string]any{"der":base64.RawURLEncoding.EncodeToString(der),"digest":fmt.Sprintf("sha256:%x",d),"envelope":map[string]any{"rotation_id":"22222222-2222-4222-8222-222222222222","activate":false,"current_version":1,"profile_version":2,"profile_digest":fmt.Sprintf("sha256:%x",d),"deadline_at":now.Add(time.Hour).Format(time.RFC3339),"profile":map[string]any{"version":p.Version,"device_id":p.Device,"client_public_key":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=","protocol":p.Protocol,"server":p.Server,"port":p.Port,"server_public_key":p.ServerKey,"preshared_key":p.PSK,"assigned_ipv4":p.IPv4,"dns":p.DNS,"allowed_ips":p.Allowed,"routing_policy_version":"outer-nonempty","expires_at":now.Add(time.Hour).Format(time.RFC3339),"amnezia":p.AWG,"authorization":map[string]any{"algorithm":"ECDSA_P256_SHA256_DER","key_id":"k","payload_base64":base64.RawURLEncoding.EncodeToString(raw),"signature_base64":base64.RawURLEncoding.EncodeToString(sig)}}}}; json.NewEncoder(os.Stdout).Encode(out) }'''
SWIFT=r'''
import Foundation
struct Fixture:Decodable {let der:String;let digest:String;let envelope:PSKRotationCurrentResponse}
@main @MainActor struct Main {
 static func need(_ b:Bool,_ m:String){if !b {fputs("FAIL: \(m)\n",stderr);exit(1)}}
 static func event(_ k:NativePushPSKEvent.Kind,_ id:String,_ e:PSKRotationCurrentResponse)->NativePushPSKEvent { NativePushPSKEvent(kind:k,eventID:id,rotationID:e.rotationID,deviceID:e.profile.deviceId!,profileVersion:e.profileVersion,deadlineAt:nil) }
 static func main() async {
  let f=try! JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  let der=Data(base64Encoded:f.der.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-f.der.count%4)%4))!
  let verifier=NativeVPNProfileAuthorizationVerifier(pinnedPublicKeyDER:[f.envelope.profile.authorization!.keyID:der]);
  let route=CommandLine.arguments[3]; let region=CommandLine.arguments[4].isEmpty ? nil : CommandLine.arguments[4]
  let auth=f.envelope.profile.authorization!;let payload=Data(base64Encoded:auth.payloadBase64.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-auth.payloadBase64.count%4)%4))!
  let policy=try! JSONSerialization.jsonObject(with:payload) as! [String:Any];let signedTunnel=policy["tunnel"] as! [String:Any]
  let expectedMTU=signedTunnel["mtu"] as! Int;let expectedKeepalive=signedTunnel["persistent_keepalive"] as! Int
  let explicitRouting=policy["routing_mode"] != nil;
 let owner=NativePushPSKEventOwner(accountID:"owner",installationID:"install")!; let dev=f.envelope.profile.deviceId!; let root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true); let q=NativePushPSKEventQueue(appDataURL:root); let store=NativePSKStagedProfileStore(appDataURL:root)
  func validate(_ e:PSKRotationCurrentResponse,_ x:NativePushPSKEvent) throws { guard e.rotationID==x.rotationID, e.profileVersion==x.profileVersion, e.profile.deviceId == dev, e.profile.clientPublicKey == f.envelope.profile.clientPublicKey, e.profileDigest == f.digest else { throw NativeVPNProfileAuthorizationVerifier.Failure.policyMismatch }; let v=try verifier.verifyDetailed(e,ownerAccountID:"owner",managedDeviceID:dev,locationID:"loc",routingMode:route,bypassRegion:region); let versionOK = explicitRouting ? v.envelope.profile.routingPolicyVersion == f.envelope.profile.routingPolicyVersion : v.envelope.profile.routingPolicyVersion == nil
    need(v.envelope.profile.authorization==nil && versionOK && v.mtu==expectedMTU && v.persistentKeepalive==expectedKeepalive,"signed routing/config")
    let admission=NativePushPSKEvent(kind:.profile_updated,eventID:x.eventID,rotationID:x.rotationID,deviceID:x.deviceID,profileVersion:x.profileVersion,deadlineAt:x.deadlineAt)
    try NativePSKRotationValidation.validate(envelope:v.envelope,event:admission,managedDeviceID:dev,expectedClientPublicKey:f.envelope.profile.clientPublicKey,requireStagingDeadline:x.kind == .profile_updated)
    if route == "all_except_ru" { need(v.envelope.profile.allowedIps?.contains("0.0.0.0/0") == false,"split cannot be full IPv4") } }
  var acks=0, activates=0
  let deps=NativePSKEventConsumer.Dependencies(scopeIsCurrent:{true},fetchCurrent:{f.envelope},validate:validate,acknowledge:{ e in let saved=try store.load(owner:owner,managedDeviceID:dev,rotationID:e.rotationID)!; need(saved.envelope.profile.authorization == e.profile.authorization && saved.envelope.profileDigest==f.digest,"ACK exact durable signed proof/digest"); acks += 1; return PSKRotationACKResponse(rotationID:e.rotationID,accepted:true,replayed:false)},activate:{ e,_ in let v=try verifier.verifyDetailed(e,ownerAccountID:"owner",managedDeviceID:dev,locationID:"loc",routingMode:route,bypassRegion:region); need(v.mtu==expectedMTU && v.persistentKeepalive==expectedKeepalive,"activate signed values"); activates += 1},didFail:{ error in fputs("stage chain error: \(error)\n",stderr)})
  try! q.enqueue(event(.profile_updated,"33333333-3333-4333-8333-333333333333",f.envelope),owner:owner); let c=NativePSKEventConsumer(queue:q,store:store); await c.process(owner:owner,managedDeviceID:dev,dependencies:deps); need(acks==1 && activates==0 && (try! q.events(owner:owner)).isEmpty,"stage reload ACK")
  // New consumer proves restart retained the original signed material before activation.
  try! q.enqueue(event(.cutover_ready,"44444444-4444-4444-8444-444444444444",f.envelope),owner:owner); let restarted=NativePSKEventConsumer(queue:q,store:NativePSKStagedProfileStore(appDataURL:root)); await restarted.process(owner:owner,managedDeviceID:dev,dependencies:deps); need(activates==1 && (try! q.events(owner:owner)).isEmpty,"restart cutover")
  // Cutover first is retained; a subsequent update stages, then the next pass activates.
  let r=URL(fileURLWithPath:root.path+"-order",isDirectory:true);let q2=NativePushPSKEventQueue(appDataURL:r);let s2=NativePSKStagedProfileStore(appDataURL:r);let c2=NativePSKEventConsumer(queue:q2,store:s2);try! q2.enqueue(event(.cutover_ready,"55555555-5555-4555-8555-555555555555",f.envelope),owner:owner);await c2.process(owner:owner,managedDeviceID:dev,dependencies:deps);need((try! q2.events(owner:owner)).count==1,"out of order retained");try! q2.enqueue(event(.profile_updated,"66666666-6666-4666-8666-666666666666",f.envelope),owner:owner);let d2=NativePSKEventConsumer.Dependencies(scopeIsCurrent:{true},fetchCurrent:{f.envelope},validate:validate,acknowledge:{_ in PSKRotationACKResponse(rotationID:f.envelope.rotationID,accepted:true,replayed:false)},activate:{_,_ in activates += 1});await c2.process(owner:owner,managedDeviceID:dev,dependencies:d2);await c2.process(owner:owner,managedDeviceID:dev,dependencies:d2);need(activates==2,"out of order next pass")
  func reject(_ name:String,_ mutate:(inout PSKRotationCurrentResponse)->Void){var e=f.envelope;mutate(&e);do{try validate(e,event(.profile_updated,"77777777-7777-4777-8777-777777777777",e));need(false,name)}catch{}}
  reject("missing trust"){ $0.profile.authorization=nil }; reject("signature tamper"){ $0.profile.authorization!.signatureBase64="A" }; reject("digest mismatch"){ $0.profileDigest="sha256:bad" }; reject("client key"){ $0.profile.clientPublicKey=nil }; reject("wrong tuple"){ $0.profile.deviceId="99999999-9999-4999-8999-999999999999" }; reject("expired"){ $0.profile.expiresAt="2000-01-01T00:00:00Z" }; reject("unsigned route geometry"){ $0.profile.allowedIps=["192.0.2.0/24"] }; if explicitRouting { reject("unsigned policyversion"){ $0.profile.routingPolicyVersion="other" } }; do { _=try verifier.verifyDetailed(f.envelope,ownerAccountID:"owner",managedDeviceID:dev,locationID:"loc",routingMode:"smart"); need(false,"routing") } catch {}
  var injected=f.envelope; injected.profile.bypassRanges=["0.0.0.0/0"]; injected.profile.bypassDomains=["unsigned.example"]
  let sanitized=try! verifier.verifyDetailed(injected,ownerAccountID:"owner",managedDeviceID:dev,locationID:"loc",routingMode:route,bypassRegion:region).envelope
  need(sanitized.profile.bypassRanges == nil && sanitized.profile.bypassDomains == nil,"unsigned bypass metadata not admitted")
  print("signed stage chain runtime: PASS route=\(route) (offline actual verifier/geometry/digest/stage/reload/ACK/restart/cutover/negative cases)")
 }
}'''
temp_root=pathlib.Path(os.environ.get("TMPDIR", str(ROOT/"macos-native/.build-offline-tmp")));temp_root.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='signed-stage-',dir=str(temp_root)) as td:
 t=pathlib.Path(td); (t/'f.go').write_text(GO); (t/'main.swift').write_text(SWIFT)
 if args.fixture: fixture=pathlib.Path(args.fixture).read_text()
 else:
  env=os.environ.copy();env.update(GOPROXY="off",GOSUMDB="off",GOTOOLCHAIN="local",GOTMPDIR=str(temp_root))
  generated=subprocess.run(['go','run',str(t/'f.go')],capture_output=True,text=True,env=env)
  sys.stdout.write(generated.stdout if generated.returncode else "");sys.stderr.write(generated.stderr)
  if generated.returncode: raise SystemExit(generated.returncode)
  fixture=generated.stdout
 (t/'fixture.json').write_text(fixture); out=t/'state';out.mkdir()
 files=[S/'Models/VEXModels.swift',S/'Services/NativePushSecureFileStore.swift',S/'Services/NativePushPSKEventQueue.swift',S/'Services/NativePSKStagedProfileStore.swift',S/'Services/NativePSKRotationValidation.swift',S/'Services/NativeVPNProfileAuthorizationVerifier.swift',S/'Services/NativePSKEventConsumer.swift',t/'main.swift']
 c=subprocess.run(['swiftc','-parse-as-library',*map(str,files),'-o',str(t/'fixture')],text=True,capture_output=True);sys.stdout.write(c.stdout);sys.stderr.write(c.stderr)
 if c.returncode: raise SystemExit(c.returncode)
 r=subprocess.run([str(t/'fixture'),str(t/'fixture.json'),str(out),args.routing_mode,args.bypass_region or ''],text=True,capture_output=True);sys.stdout.write(r.stdout);sys.stderr.write(r.stderr);raise SystemExit(r.returncode)
