#!/usr/bin/env python3
"""Compile exact staged-PSK service bodies in an inert, strongly typed runtime harness."""
import pathlib,re,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]) if len(sys.argv)==2 else pathlib.Path(__file__).resolve().parents[2]
source=(root/'macos-native/Sources/VEXNativeMac/Services/VPNProfileService.swift').read_text(); admission=(root/'macos-native/Sources/VEXHelperCore/AwgConfigAdmission.swift').read_text().replace('import Darwin\n','').replace('import Foundation\n','').replace('public enum AwgConfigAdmission','enum ActualAwgConfigAdmission'); keys=(root/'macos-native/Sources/VEXNativeMac/Services/WireGuardKeyStore.swift').read_text()
def extract(name):
 m=re.search(r'func '+name+r'\b',source); assert m,name
 i=source.find('{',m.end());d=0
 for j in range(i,len(source)):
  d += source[j]=='{'; d -= source[j]=='}'
  if not d:return source[m.start():j+1]
 raise AssertionError(name)
existing,prepare,promote=map(extract,['existingStagedPSKClientPublicKey','prepareStagedPSKProfile','promoteStagedPSKProfile'])
assert re.search(r'func existingForStagedProfile\(\) -> WireGuardKeyPair\? \{\s*loadFromFile\(\)\s*\}',keys,re.S)
harness=r'''import Foundation
import Darwin
enum HelperError: Error { case protocolViolation(String) }
'''+admission+'''
enum VEXHelperCore { typealias AwgConfigAdmission = ActualAwgConfigAdmission }
import Foundation
import CryptoKit
struct WireGuardKeyPair { let privateKey:String;let publicKey:String;let keyEpoch:Int }
final class WireGuardKeyStore { var pair:WireGuardKeyPair?; var reads=0; func existingForStagedProfile()->WireGuardKeyPair? { reads += 1; return pair } }
struct NativePushPSKEventOwner { let accountID:String;let installationID:String }
struct VPNProfileCacheOwner { init?(accountID:String,installationID:String){guard !accountID.isEmpty,!installationID.isEmpty else{return nil} } }
enum VPNProfileError:Error { case incompleteProfile(String) }
struct Profile { var deviceId:String?;var version:Int?;var clientPublicKey:String?;var bypassRanges:[String]?;var bypassDomains:[String]?;var routingPolicyVersion:String?;var mtu:Int?;var keepalive:Int? }
struct Envelope { var activate:Bool;var profileVersion:Int;var profile:Profile }
enum NativeVPNProfileAuthorizationVerifier { struct Verified { var envelope:Envelope;var mtu:Int;var persistentKeepalive:Int } }
struct Device { let id:String; func withManagedProfile(_ p:Profile,locationId:String)->Device { self } }
struct PreparedTunnel { let device:Device;let config:String;let locationId:String;let profileVersion:Int?;let routingMode:String;let bypassRegion:String?;let bypassRangesCount:Int;let bypassDomainsCount:Int;let routingPolicyVersion:String;let rotationRequired:Bool;let awgVersion:Int }
struct PreparedTunnelCacheRecord { let tunnel:PreparedTunnel }
final class VPNProfileCache { var saves=0;var owners=0;func save(_ r:PreparedTunnelCacheRecord,locationId:String,routingMode:String,owner:VPNProfileCacheOwner)throws{saves+=1;owners+=1} }
final class VPNProfileService { let keyStore:WireGuardKeyStore;let cache:VPNProfileCache;static let awgVersion=3;static var builds=0;static var lastMTU=0;static var lastKeepalive=0;static var badBuild=false;init(_ k:WireGuardKeyStore,_ c:VPNProfileCache){keyStore=k;cache=c}
 static func buildRawManagedProfileConfig(_ p:Profile,keyPair:WireGuardKeyPair,mtu:Int,persistentKeepalive:Int,resolveEndpoint:Bool)throws->String { precondition(!resolveEndpoint);builds+=1;lastMTU=mtu;lastKeepalive=persistentKeepalive;if badBuild { return "[Interface]\\nPrivateKey = bad" }; let k=Data(repeating:0,count:32).base64EncodedString(); return "[Interface]\\nPrivateKey = \(k)\\nAddress = 10.0.0.2/32\\nMTU = \(mtu)\\n[Peer]\\nPublicKey = \(k)\\nPresharedKey = \(k)\\nEndpoint = example.com:51820\\nAllowedIPs = 0.0.0.0/0\\nPersistentKeepalive = \(persistentKeepalive)" }
'''+existing+'\n'+prepare+'\n'+promote+'''\n}
func need(_ v:Bool,_ m:String){if !v{fputs("FAIL: \\(m)\\n",stderr);exit(1)}}
let privateKey=Curve25519.KeyAgreement.PrivateKey();let pair=WireGuardKeyPair(privateKey:privateKey.rawRepresentation.base64EncodedString(),publicKey:privateKey.publicKey.rawRepresentation.base64EncodedString(),keyEpoch:1);let key=WireGuardKeyStore();let cache=VPNProfileCache();let service=VPNProfileService(key,cache)
let profile=Profile(deviceId:"d",version:2,clientPublicKey:pair.publicKey,bypassRanges:["a"],bypassDomains:["b"],routingPolicyVersion:"rp",mtu:nil,keepalive:nil);let verified=NativeVPNProfileAuthorizationVerifier.Verified(envelope:Envelope(activate:false,profileVersion:2,profile:profile),mtu:1420,persistentKeepalive:27);let old=PreparedTunnel(device:Device(id:"d"),config:"old",locationId:"loc",profileVersion:1,routingMode:"full",bypassRegion:nil,bypassRangesCount:0,bypassDomainsCount:0,routingPolicyVersion:"old",rotationRequired:false,awgVersion:3)
for p in [nil,WireGuardKeyPair(privateKey:"bad",publicKey:pair.publicKey,keyEpoch:1),WireGuardKeyPair(privateKey:pair.privateKey,publicKey:Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),keyEpoch:1)] {key.pair=p;do{_ = try service.existingStagedPSKClientPublicKey();need(false,"bad key accepted")}catch{}}
key.pair=pair;let staged=try service.prepareStagedPSKProfile(verified,basedOn:old);need(staged.config.contains("MTU = 1420") && staged.config.contains("PersistentKeepalive = 27") && VPNProfileService.lastMTU==1420 && VPNProfileService.lastKeepalive==27,"builder values");need(cache.saves==0,"cache before promote")
var wrong=verified;wrong.envelope.profile.deviceId="x";do{_ = try service.prepareStagedPSKProfile(wrong,basedOn:old);need(false,"wrong device")}catch{};wrong=verified;wrong.envelope.profileVersion=1;do{_ = try service.prepareStagedPSKProfile(wrong,basedOn:old);need(false,"wrong version")}catch{}
VPNProfileService.badBuild=true;do{_ = try service.prepareStagedPSKProfile(verified,basedOn:old);need(false,"bad generated config accepted")}catch{};need(cache.saves==0,"bad config cache write");VPNProfileService.badBuild=false
try service.promoteStagedPSKProfile(staged,owner:NativePushPSKEventOwner(accountID:"a",installationID:"i"));need(cache.saves==1 && cache.owners==1,"exact owner promotion");print("actual extracted preparation runtime passed")
'''
with tempfile.TemporaryDirectory(prefix='psk-prepare-',dir='/private/tmp') as d:
 p=pathlib.Path(d);(p/'main.swift').write_text(harness);c=subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'fixture')],text=True,capture_output=True);print(c.stdout,end='');print(c.stderr,end='',file=sys.stderr)
 if c.returncode:raise SystemExit(c.returncode)
 r=subprocess.run([str(p/'fixture')],text=True,capture_output=True);print(r.stdout,end='');print(r.stderr,end='',file=sys.stderr);raise SystemExit(r.returncode)
