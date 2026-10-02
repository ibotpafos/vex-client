#!/usr/bin/env python3
"""Real normal persistence/renderer/session write boundaries with inert ports only."""
from pathlib import Path
import os,re,subprocess,sys,tempfile,hashlib,json
ROOT=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac'
source=(S/'Services/VPNProfileService.swift').read_text()
def extract(name):
    m=re.search(r'(?m)^    (?:nonisolated )?(?:private )?(?:static )?func '+name+r'\(',source)
    assert m,name
    i=source.index('(',m.start()); n=0
    for j in range(i,len(source)):
        n+=(source[j]=='(')-(source[j]==')')
        if not n: break
    i=source.index('{',j+1);n=0
    for j in range(i,len(source)):
        n+=(source[j]=='{')-(source[j]=='}')
        if not n:return source[m.start():j+1]
    raise AssertionError(name)
names=['resolveProfile','persistManagedProfile','writeSanitizedHelperConfig','buildRawManagedProfileConfig','amneziaConfig','managedProfileEndpoint','clean','addNumber','addString']
bodies='\n'.join(extract(n) for n in names)
admission=(ROOT/'macos-native/Sources/VEXHelperCore/AwgConfigAdmission.swift').read_text().replace('public enum AwgConfigAdmission','enum ActualAwgConfigAdmission')
device=source[source.index('private extension VpnDevice {'):source.index('\nextension PreparedTunnel {')]
cache_source=(S/'Services/VPNProfileCache.swift').read_text()
cache_models=cache_source[cache_source.index('struct VPNProfileCacheOwner:'):cache_source.index('\nstruct VPNProfileCache {')]+cache_source[cache_source.index('struct PreparedTunnelCacheRecord:'):]
harness=r'''
import Foundation
import CryptoKit
enum HelperError: Error { case protocolViolation(String) }
ADMISSION
enum VEXHelperCore { typealias AwgConfigAdmission = ActualAwgConfigAdmission }
enum VPNProfileError: Error { case subscriptionInactive, deviceRevoked, unchangedProfileWithoutCache, incompleteProfile(String) }
enum FixtureError: Error { case sessionChanged, cacheFailure }
CACHE_MODELS
@MainActor final class Cache {
 var writes=0;var helperWrites=0;var loads=0;var fail=false;var saved:PreparedTunnelCacheRecord?
 func load(locationId:String,routingMode:VpnRoutingMode,owner:VPNProfileCacheOwner)->PreparedTunnelCacheRecord? {loads+=1;return saved}
 func save(_ r:PreparedTunnelCacheRecord,locationId:String,routingMode:VpnRoutingMode,owner:VPNProfileCacheOwner)throws {
  if fail {throw FixtureError.cacheFailure};precondition(owner.accountID=="owner");writes+=1;var owned=r;owned.cacheOwner=owner;saved=owned
 }
 func writeHelperConfig(_ config:String)throws {helperWrites+=1}
}
DEVICE
@MainActor final class FakeIdentity {var reads=0;func getOrCreateDeviceId()->String {reads+=1;return "installation"}}
@MainActor final class FakeKeys {var reads=0;func getOrCreate()throws->WireGuardKeyPair {reads+=1;return pair}}
@MainActor final class FakeAPI {
 var response:ManagedVpnProfile?;var mode="working";var profileCalls=0;var lastRequest="";var lastRoute:VpnRoutingMode?;var lastKnown:Int?
 var after:((String)->Void)?
 func entitlement(accessToken:String)async throws->Entitlement {await Task.yield();after?("entitlement");return Entitlement(active:true,vpnAccess:true)}
 func rotateManagedVpnKey(accessToken:String,deviceId:String,keyPair:WireGuardKeyPair,prefix:String)async throws->VpnDevice {fatalError("unexpected rotation")}
 func managedVpnProfile(accessToken:String,deviceId:String,locationId:String,routingMode:VpnRoutingMode,bypassRegion:String?,knownVersion:Int?)async throws->ManagedVpnProfile {
  profileCalls+=1;lastRequest=locationId;lastRoute=routingMode;lastKnown=knownVersion;await Task.yield();after?("profile")
  if mode=="timeout" {throw URLError(.timedOut)}
  if mode=="provision" {throw URLError(.cannotLoadFromNetwork)}
  return response!
 }
}
@MainActor final class Harness {
 let cache=Cache();static let awgVersion=3
 let api=FakeAPI();let identityStore=FakeIdentity();let keyStore=FakeKeys()
 private func bypassRegion(for route:VpnRoutingMode)->String? {route == .fullTunnel ? nil:"ru"}
 private func needsKeySync(device:VpnDevice,keyPair:WireGuardKeyPair)->Bool {false}
 private func activeDevice(accessToken:String,externalDeviceId:String,publicKey:String,keyEpoch:Int,locationId:String,validateCurrent:@MainActor ()throws->Void)async throws->VpnDevice {await Task.yield();api.after?("device");return device}
 let profileAuthorization:NativeVPNProfileAuthorizationVerifier
 init(){profileAuthorization=NativeVPNProfileAuthorizationVerifier(pinnedPublicKeyDER:["k":signer.publicKey.derRepresentation])}
 // Only sanitizer's detached DNS work is replaced by an inert suspension.
 // The actual writeSanitizedHelperConfig body and both guards are extracted.
 nonisolated private static func sanitizedHelperConfigOffMain(_ config:String)async ->String {await Task.yield();return config}
 nonisolated private static func resolveConfigEndpoint(_ endpoint:String)->String {fatalError("DNS must never be called")}
 BODIES
 func admit(_ p:ManagedVpnProfile,owner:VPNProfileCacheOwner?=VPNProfileCacheOwner(accountID:"owner",installationID:"installation"),pair:WireGuardKeyPair=pair,dev:VpnDevice=device,request:String="de",cached:PreparedTunnelCacheRecord?=nil,guardAt:Int=0,helper:Bool=false,route:VpnRoutingMode = .fullTunnel,region:String?=nil)async throws->PreparedTunnel {
  var checks=0
  return try await persistManagedProfile(p,cached:cached,cacheOwner:owner,device:dev,keyPair:pair,locationId:request,routingMode:route,bypassRegion:region,writeHelperConfig:helper,validateCurrent:{
   checks+=1;if checks==guardAt {throw FixtureError.sessionChanged}
  })
 }
}
let signer=P256.Signing.PrivateKey()
let privateKey=Curve25519.KeyAgreement.PrivateKey()
let pair=WireGuardKeyPair(privateKey:privateKey.rawRepresentation.base64EncodedString(),publicKey:privateKey.publicKey.rawRepresentation.base64EncodedString(),keyEpoch:2)
let k=Data(repeating:7,count:32).base64EncodedString()
let iso=ISO8601DateFormatter()
let now=Date()
let device=try! JSONDecoder().decode(VpnDevice.self,from:JSONSerialization.data(withJSONObject:["id":"device","status":"active","public_key":pair.publicKey,"platform":"macos","provisioning_mode":"managed_native","client_key_ownership":"client"]))
func url64(_ data:Data)->String {data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
func profile(request:String="de",policyChange:(inout [String:Any])->Void={_ in})throws->ManagedVpnProfile {
 var policy:[String:Any]=["schema":"vex.native-vpn-profile.v1","user_id":"owner","device_id":"device","assigned_location_id":"assigned","routing_mode":"full_tunnel","profile_version":7,"issued_at":iso.string(from:now.addingTimeInterval(-2)),"expires_at":iso.string(from:now.addingTimeInterval(3600)),"tunnel":["protocol":"wireguard","endpoint":"vpn.example:51820","assigned_ipv4":"10.0.0.2/32","server_public_key":k,"preshared_key":k,"dns":["9.9.9.9"],"allowed_ips":["0.0.0.0/0"],"mtu":1420,"persistent_keepalive":55]]
 if !request.isEmpty {policy["requested_location_id"]=request}
 policyChange(&policy)
 let payload=try JSONSerialization.data(withJSONObject:policy,options:[.sortedKeys])
 let raw:[String:Any]=["device_id":"device","client_public_key":pair.publicKey,"client_key_epoch":2,"version":7,"protocol":"wireguard","server":"vpn.example","port":51820,"assigned_ipv4":"10.0.0.2/32","server_public_key":k,"preshared_key":k,"dns":["9.9.9.9"],"allowed_ips":["0.0.0.0/0"],"expires_at":iso.string(from:now.addingTimeInterval(3600)),"config":"[Interface]\nPrivateKey = UNSIGNED_EVIL\n[Peer]\nEndpoint = evil.example:1","bypass_domains":["unsigned.example"],"bypass_ranges":["unsigned"],"authorization":["algorithm":"ECDSA_P256_SHA256_DER","key_id":"k","payload_base64":url64(payload),"signature_base64":url64(try signer.signature(for:payload).derRepresentation)]]
 return try JSONDecoder().decode(ManagedVpnProfile.self,from:JSONSerialization.data(withJSONObject:raw))
}
func need(_ b:Bool,_ s:String){if !b {fputs("FAIL: \(s)\n",stderr);exit(1)}}
@main struct Main {
 @MainActor static func main()async throws {
  let original=try profile()
  let good=Harness()
  let rendered=try await good.admit(original,helper:true)
  need(good.cache.writes==1 && good.cache.helperWrites==1,"valid signed writes")
  need(rendered.config.contains("PrivateKey = \(pair.privateKey)") && rendered.config.contains("MTU = 1420") && rendered.config.contains("PersistentKeepalive = 55"),"local key and signed geometry")
  need(rendered.config.contains("Endpoint = vpn.example:51820") && !rendered.config.contains("UNSIGNED_EVIL") && !rendered.config.contains("evil.example"),"opaque outer config ignored")
  need(rendered.bypassRangesCount==0 && rendered.bypassDomainsCount==0 && rendered.profileVersion==7 && rendered.device.id=="device","unsigned bypass stripped")
  print("valid_signed_normal_profile: local-key rendering, signed MTU/keepalive, opaque config ignored, cache=1/helper=1")
  let auto=Harness()
  let autoTunnel=try await auto.admit(profile(request:""),request:"")
  need(auto.cache.writes==1 && autoTunnel.locationId=="","auto signed request omission; no guessed assignment input")
  print("auto request omission: verified signed assignment; cache=1")
  var rejects=0
  func reject(_ label:String,_ p:ManagedVpnProfile,owner:VPNProfileCacheOwner?=VPNProfileCacheOwner(accountID:"owner",installationID:"installation"),key:WireGuardKeyPair=pair,dev:VpnDevice=device,request:String="de",cached:PreparedTunnelCacheRecord?=nil,guardAt:Int=0)async {
   let h=Harness()
   do {_=try await h.admit(p,owner:owner,pair:key,dev:dev,request:request,cached:cached,guardAt:guardAt,helper:true);need(false,"accepted \(label)")} catch {}
   need(h.cache.writes==0 && h.cache.helperWrites==0,"writes on rejection \(label)")
   rejects+=1;print("rejected \(label): cache=0/helper=0")
  }
  var p=original;p.authorization=nil;await reject("missing_authorization",p)
  p=original;p.authorization!.signatureBase64="A";await reject("invalid_signature",p)
  p=original;p.authorization!.keyID="unknown";await reject("unknown_anchor",p)
  p=original;p.deviceId="other";await reject("outer_device",p)
  p=original;p.version=8;await reject("outer_version",p)
  p=original;p.version=0;await reject("zero_version",p)
  p=original;p.revoked=true;await reject("revoked",p)
  p=original;p.unchanged=true;await reject("unchanged_even_with_cache",p,cached:good.cache.saved)
  p=original;p.clientPublicKey=k;await reject("profile_public_key",p)
  p=original;p.clientKeyEpoch=3;await reject("profile_epoch",p)
  var wrongDevice=device;wrongDevice.publicKey=k;await reject("device_public_key",original,dev:wrongDevice)
  await reject("private_key_mismatch",original,key:WireGuardKeyPair(privateKey:Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),publicKey:pair.publicKey,keyEpoch:2))
  await reject("missing_owner",original,owner:nil)
  await reject("wrong_owner",original,owner:VPNProfileCacheOwner(accountID:"other",installationID:"installation"))
  await reject("wrong_request",original,request:"other")
  await reject("session_at_entry",original,guardAt:1)
  await reject("session_before_cache",original,guardAt:2)
  await reject("signed_expired",try profile{$0["expires_at"]=iso.string(from:now.addingTimeInterval(-1))})
  let helperGuard=Harness()
  do {_=try await helperGuard.admit(original,guardAt:4,helper:true);need(false,"late helper currentness")}catch{}
  need(helperGuard.cache.writes==1 && helperGuard.cache.helperWrites==0,"valid earlier cache, obsolete helper blocked after await")
  print("session_after_sanitizer: prior valid cache=1/helper=0; no obsolete helper write")
  let failing=Harness();failing.cache.fail=true
  do {_=try await failing.admit(original,helper:true);need(false,"cache error")}catch{}
  need(failing.cache.writes==0 && failing.cache.helperWrites==0,"cache failure blocks helper")
  print("normal persistence matrix PASS rejects=\(rejects); actual production methods/models/CryptoKit/AWG admission; inert cache/helper only")
  let resolver=Harness();resolver.api.response=original;resolver.cache.saved=good.cache.saved
  _=try await resolver.resolveProfile(accessToken:"fixture",locationId:" De ",routingMode:.fullTunnel,writeHelperConfig:false,accountID:"owner")
  need(resolver.api.profileCalls==1 && resolver.api.lastRequest=="de" && resolver.api.lastKnown==nil && resolver.cache.loads==0 && resolver.cache.writes==1,"normal resolver fresh full response, not seeded cache")
  print("actual resolver: normalized request=de, full signed fetch=1, knownVersion=nil, legacy cache loads=0")
  for route in [VpnRoutingMode.fullTunnel,.allExceptRu] {
   for mode in ["timeout","provision"] {
    let h=Harness();h.api.mode=mode;h.cache.saved=good.cache.saved
    do {_=try await h.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:route,writeHelperConfig:true,accountID:"owner");need(false,"fallback on \(mode)")}catch{}
    need(h.api.profileCalls==1 && h.api.lastRoute==route && h.cache.loads==0 && h.cache.writes==0 && h.cache.helperWrites==0,"no silent route/timeout fallback")
    print("actual resolver \(route.rawValue)/\(mode): calls=1, cache/helper=0, no route fallback")
   }
  }
  for point in ["entitlement","device","profile"] {
   var current=true;let h=Harness();h.api.response=original;h.api.after={if $0==point {current=false}}
   do {_=try await h.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:true,accountID:"owner",validateCurrent:{if !current {throw FixtureError.sessionChanged}});need(false,"obsolete resolver \(point)")}catch{}
   need(h.cache.writes==0 && h.cache.helperWrites==0,"obsolete resolver writes \(point)")
   if point=="entitlement" {need(h.keyStore.reads==0 && h.api.profileCalls==0,"obsolete entitlement must stop before key creation")}
   print("actual resolver session changed after \(point): cache/helper=0")
  }
  let missingOwner=Harness()
  do {_=try await missingOwner.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,accountID:nil);need(false,"missing resolver owner")}catch{}
  need(missingOwner.identityStore.reads==0 && missingOwner.keyStore.reads==0 && missingOwner.api.profileCalls==0,"owner rejection before identities")
  print("normal resolver matrix PASS; actual resolveProfile body, API/identity/key/active-device ports inert; no live calls")
 }
}
'''.replace('ADMISSION',admission).replace('DEVICE',device).replace('BODIES',bodies).replace('CACHE_MODELS',cache_models)
# No application/helper, OS preferences, Keychain, DNS, network, route/PF or VPN use.
tmp=Path(os.environ.get('TMPDIR','/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-20-native/tmp'));tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='normal-persistence-',dir=tmp) as p:
 d=Path(p);(d/'fixture.swift').write_text(harness)
 cmd=['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',str(S/'Models/VEXModels.swift'),str(S/'Services/NativeVPNProfileAuthorizationVerifier.swift'),str(S/'Services/NativeAwgBoolean.swift'),str(d/'fixture.swift'),'-o',str(d/'probe')]
 subprocess.run(cmd,check=True)
 subprocess.run(['rtk','proxy',str(d/'probe')],check=True)
