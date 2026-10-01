#!/usr/bin/env python3
"""Runs a standalone Swift runtime fixture against production PSK models and validator."""
import subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).parents[2]; SRC=ROOT/'macos-native/Sources/VEXNativeMac'
GO=r'''package main
import("crypto/sha256";"encoding/json";"fmt")
type A struct { Jc int `json:"jc,omitempty"`; H1 string `json:"h1,omitempty"`; Header string `json:"header_protection_key,omitempty"`; Keep string `json:"persistent_keepalive,omitempty"` }
type S struct { Version int `json:"version"`; Device string `json:"device_id"`; Protocol string `json:"protocol"`; Server string `json:"server"`; Port int `json:"port"`; SPK string `json:"server_public_key"`; PSK string `json:"preshared_key"`; IP string `json:"assigned_ipv4"`; DNS []string `json:"dns"`; Allowed []string `json:"allowed_ips"`; A *A `json:"amnezia,omitempty"` }
func main(){ b,_:=json.Marshal(S{2,"11111111-1111-4111-8111-111111111111","awg3","vpn.example.com",51820,"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=","10.0.0.2/32",[]string{"1.1.1.1","2001:4860:4860::8888"},[]string{"0.0.0.0/0","::/0"},&A{Jc:1,H1:"<>&\u2028\u2029",Header:"x/y",Keep:"31"}}); fmt.Printf("sha256:%x",sha256.Sum256(b)) }'''
with tempfile.TemporaryDirectory() as d:
 d=Path(d); (d/'golden.go').write_text(GO)
 golden=subprocess.check_output(['go','run','golden.go'],cwd=d,text=True).strip()
 fixture=f'''import Foundation
func require(_ ok: @autoclosure () -> Bool) {{ if !ok() {{ fatalError("assertion") }} }}
let key1 = Data(repeating: 1, count: 32).base64EncodedString()
let key2 = Data(repeating: 2, count: 32).base64EncodedString()
let raw = #"{{"version":2,"device_id":"11111111-1111-4111-8111-111111111111","protocol":"awg3","server":"vpn.example.com","port":51820,"server_public_key":"\#(key1)","preshared_key":"\#(key2)","client_public_key":"\#(key1)","assigned_ipv4":"10.0.0.2/32","dns":["1.1.1.1","2001:4860:4860::8888"],"allowed_ips":["0.0.0.0/0","::/0"],"expires_at":"2030-01-01T00:00:00Z","amnezia":{{"jc":1,"h1":"<>&\\u2028\\u2029","header_protection_key":"x/y","persistent_keepalive":"31"}}}}"#
var p = try! JSONDecoder().decode(ManagedVpnProfile.self, from: Data(raw.utf8))
let golden = "{golden}"
require(NativePSKRotationValidation.serverStableDigest(p) == golden)
func e(_ profile: ManagedVpnProfile = p, _ digest: String = golden) -> PSKRotationCurrentResponse {{ PSKRotationCurrentResponse(rotationID:"22222222-2222-4222-8222-222222222222",activate:false,currentVersion:1,profileVersion:2,profileDigest:digest,deadlineAt:"2030-01-01T00:00:00Z",profile:profile) }}
let event = NativePushPSKEvent(kind:.profile_updated,eventID:"33333333-3333-4333-8333-333333333333",rotationID:"22222222-2222-4222-8222-222222222222",deviceID:"11111111-1111-4111-8111-111111111111",profileVersion:2,deadlineAt:Date(timeIntervalSince1970:1893456000))
func rejects(_ x: PSKRotationCurrentResponse, _ ev: NativePushPSKEvent = event, _ key: String? = key1) {{ do {{ try NativePSKRotationValidation.validate(envelope:x,event:ev,managedDeviceID:"11111111-1111-4111-8111-111111111111",expectedClientPublicKey:key,now:Date(timeIntervalSince1970:1700000000)); fatalError("accepted") }} catch {{ }} }}
try NativePSKRotationValidation.validate(envelope:e(),event:event,managedDeviceID:"11111111-1111-4111-8111-111111111111",expectedClientPublicKey:nil,now:Date(timeIntervalSince1970:1700000000))
rejects(e(),event,"wrong")
var bad=p; bad.assignedIpv4="01.2.3.4"; rejects(e(bad)); bad=p; bad.dns=["::::"]; rejects(e(bad)); bad=p; bad.allowedIps=["1.2.3.4/99"]; rejects(e(bad)); bad=p; bad.authorization=ManagedVpnProfileAuthorization(algorithm:"x",keyID:"x",payloadBase64:"x",signatureBase64:"x"); rejects(e(bad)); rejects(PSKRotationCurrentResponse(rotationID:e().rotationID,activate:false,currentVersion:2,profileVersion:2,profileDigest:golden,deadlineAt:e().deadlineAt,profile:p)); rejects(PSKRotationCurrentResponse(rotationID:e().rotationID,activate:false,currentVersion:1,profileVersion:2,profileDigest:"sha256:"+String(repeating:"0",count:64),deadlineAt:e().deadlineAt,profile:p)); print("PSK runtime fixture: PASS")
'''
 (d/'main.swift').write_text(fixture)
 cmd=['swiftc',str(SRC/'Models/VEXModels.swift'),str(SRC/'Services/NativePushSecureFileStore.swift'),str(SRC/'Services/NativePushPSKEventQueue.swift'),str(SRC/'Services/NativePSKRotationValidation.swift'),str(d/'main.swift'),'-o',str(d/'fixture')]
 subprocess.run(cmd,check=True); out=subprocess.check_output([str(d/'fixture')],text=True); assert 'PASS' in out
print('NativePSKRotationValidation runtime/Go-digest fixture: PASS')
