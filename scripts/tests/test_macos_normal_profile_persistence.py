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
for name in ['prepareVerifiedNormalCache','invalidateNormalCache']:
    if 'func '+name+'(' in source:names.append(name)
bodies='\n'.join(extract(n) for n in names)
control=source[source.index('@MainActor\nfinal class NativeNormalProfileCacheReuseControl'):source.index('\nenum VPNProfileError:')] if 'final class NativeNormalProfileCacheReuseControl' in source else '@MainActor final class NativeNormalProfileCacheReuseControl {}'
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
CONTROL
@MainActor final class Cache {
 var writes=0;var helperWrites=0;var loads=0;var removes=0;var fail=false;var failRemove=false;var saved:PreparedTunnelCacheRecord?
 func removeNormalProfiles(owner:VPNProfileCacheOwner)throws {removes+=1;if failRemove {throw FixtureError.cacheFailure};saved=nil}
 func load(locationId:String,routingMode:VpnRoutingMode,owner:VPNProfileCacheOwner)->PreparedTunnelCacheRecord? {loads+=1;return saved}
 func save(_ r:PreparedTunnelCacheRecord,locationId:String,routingMode:VpnRoutingMode,owner:VPNProfileCacheOwner)throws {
  if fail {throw FixtureError.cacheFailure};precondition(owner.accountID=="owner");writes+=1;var owned=r;owned.cacheOwner=owner;saved=owned
 }
 func writeHelperConfig(_ config:String)throws {helperWrites+=1}
}
DEVICE
@MainActor final class FakeIdentity {var reads=0;var existingReads=0;var existing:String?="installation";func existingDeviceId()->String? {existingReads+=1;return existing};func getOrCreateDeviceId()->String {reads+=1;return "installation"}}
@MainActor final class FakeKeys {var reads=0;var existingReads=0;var existing:WireGuardKeyPair?=pair;func existingForStagedProfile()->WireGuardKeyPair? {existingReads+=1;return existing};func getOrCreate()throws->WireGuardKeyPair {reads+=1;return pair}}
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
 let normalCacheReuse=NativeNormalProfileCacheReuseControl()
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
let device=try! JSONDecoder().decode(VpnDevice.self,from:JSONSerialization.data(withJSONObject:["id":"device","status":"active","public_key":pair.publicKey,"external_device_id":"installation","platform":"macos","provisioning_mode":"managed_native","client_key_ownership":"client"]))
func url64(_ data:Data)->String {data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
func profile(request:String="de",signedBinding:Bool=false,allowed:[String]=["0.0.0.0/0"],policyChange:(inout [String:Any])->Void={_ in})throws->ManagedVpnProfile {
 var policy:[String:Any]=["schema":"vex.native-vpn-profile.v1","user_id":"owner","device_id":"device","assigned_location_id":"assigned","routing_mode":"full_tunnel","profile_version":7,"issued_at":iso.string(from:now.addingTimeInterval(-2)),"expires_at":iso.string(from:now.addingTimeInterval(3600)),"tunnel":["protocol":"wireguard","endpoint":"vpn.example:51820","assigned_ipv4":"10.0.0.2/32","server_public_key":k,"preshared_key":k,"dns":["9.9.9.9"],"allowed_ips":allowed,"mtu":1420,"persistent_keepalive":55]]
 if !request.isEmpty {policy["requested_location_id"]=request}
 if signedBinding {policy["installation_id"]="installation";policy["client_public_key"]=pair.publicKey;policy["client_key_epoch"]=pair.keyEpoch}
 policyChange(&policy)
 let payload=try JSONSerialization.data(withJSONObject:policy,options:[.sortedKeys])
 let raw:[String:Any]=["device_id":"device","client_public_key":pair.publicKey,"client_key_epoch":2,"version":7,"protocol":"wireguard","server":"vpn.example","port":51820,"assigned_ipv4":"10.0.0.2/32","server_public_key":k,"preshared_key":k,"dns":["9.9.9.9"],"allowed_ips":allowed,"expires_at":iso.string(from:now.addingTimeInterval(3600)),"config":"[Interface]\nPrivateKey = UNSIGNED_EVIL\n[Peer]\nEndpoint = evil.example:1","bypass_domains":["unsigned.example"],"bypass_ranges":["unsigned"],"authorization":["algorithm":"ECDSA_P256_SHA256_DER","key_id":"k","payload_base64":url64(payload),"signature_base64":url64(try signer.signature(for:payload).derRepresentation)]]
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
  var smartProfile=try profile(signedBinding:true,allowed:["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"]){$0["routing_mode"]="all_except_ru";$0["bypass_region"]="ru";$0["routing_policy_version"]="r1";$0["bypass_ranges_count"]=2;$0["bypass_domains_count"]=3};smartProfile.routingPolicyVersion="r1"
  let smartFresh=Harness();let smartFreshTunnel=try await smartFresh.admit(smartProfile,helper:false,route:.allExceptRu,region:"ru")
  need(smartFreshTunnel.bypassRangesCount==2 && smartFreshTunnel.bypassDomainsCount==3 && smartFreshTunnel.config.contains("AllowedIPs = 0.0.0.0/1, 128.0.0.0/2, 192.0.0.0/3, 224.0.0.0/4"),"fresh smart signed counts and geometry")
  need(smartFresh.cache.saved!.normalAuthorizationProfile?.bypassRanges==["unsigned"],"signed original retained only for cache proof")
  print("fresh smart: signed count pair=2/3 and AllowedIPs retained; unsigned outer bypass lists never render")
  var legacySmart=try profile(signedBinding:true,allowed:["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"]){$0["routing_mode"]="all_except_ru";$0["bypass_region"]="ru";$0["routing_policy_version"]="r1"};legacySmart.routingPolicyVersion="r1"
  let legacyFresh=Harness();legacyFresh.api.response=legacySmart
  let legacyTunnel=try await legacyFresh.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.allExceptRu,writeHelperConfig:false,accountID:"owner")
  need(legacyFresh.api.profileCalls==1 && legacyTunnel.bypassRangesCount==0 && legacyTunnel.bypassDomainsCount==0,"fresh smart legacy omission remains compatible as derived zero")
  for malformedPolicy in [{ (p: inout [String:Any]) in p["bypass_ranges_count"]=1 }, { (p: inout [String:Any]) in p["bypass_ranges_count"] = -1;p["bypass_domains_count"]=1 }] {
    var malformed=try profile(signedBinding:true,allowed:["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"]){p in p["routing_mode"]="all_except_ru";p["bypass_region"]="ru";p["routing_policy_version"]="r1";malformedPolicy(&p)};malformed.routingPolicyVersion="r1"
    let rejectedFresh=Harness();rejectedFresh.api.response=malformed
    do {_=try await rejectedFresh.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.allExceptRu,writeHelperConfig:false,accountID:"owner");need(false,"malformed smart fresh accepted")}catch{}
    need(rejectedFresh.api.profileCalls==1 && rejectedFresh.cache.writes==0,"malformed smart fresh no cache write")
  }
  var smartOuterRoutePoison=smartProfile;smartOuterRoutePoison.allowedIps=["0.0.0.0/0"]
  do {_=try await Harness().admit(smartOuterRoutePoison,route:.allExceptRu,region:"ru");need(false,"outer smart route poison accepted")}catch{}
  var smartSignatureTamper=smartProfile;smartSignatureTamper.authorization!.signatureBase64="A"
  do {_=try await Harness().admit(smartSignatureTamper,route:.allExceptRu,region:"ru");need(false,"smart signature poison accepted")}catch{}
  print("public smart fresh: legacy omitted pair=0; partial/negative, raw route poison, and signature tamper rejected")
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
  need(resolver.api.profileCalls==1 && resolver.api.lastRequest=="de" && resolver.api.lastKnown==nil && resolver.cache.loads==1 && resolver.cache.writes==1,"normal resolver fresh full response, not legacy proof cache")
  print("actual resolver: normalized request=de, full signed fetch=1, knownVersion=nil, legacy signed-without-client-binding cache rejected")
  for route in [VpnRoutingMode.fullTunnel,.allExceptRu] {
   for mode in ["timeout","provision"] {
    let h=Harness();h.api.mode=mode;h.cache.saved=good.cache.saved
    do {_=try await h.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:route,writeHelperConfig:true,accountID:"owner");need(false,"fallback on \(mode)")}catch{}
    need(h.api.profileCalls==1 && h.api.lastRoute==route && h.cache.loads==1 && h.cache.writes==0 && h.cache.helperWrites==0,"no silent route/timeout fallback")
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
  let signed=try profile(signedBinding:true)
  let online=Harness();online.api.response=signed
  let first=try await online.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:false,accountID:"owner")
  need(online.cache.saved!.normalAuthorizationProfile?.authorization != nil,"original signature must be persisted")
  let seed=online.cache.saved!;let fetches=online.api.profileCalls;let writes=online.cache.writes
  online.api.mode="timeout";online.cache.saved!.config="UNSIGNED_CACHE_POISON"
  let second=try await online.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:false,accountID:"owner")
  need(second.config==first.config && online.api.profileCalls==fetches && online.cache.writes==writes && online.keyStore.reads==1 && online.identityStore.reads==1,"offline uses signed proof and existing readonly key, not poison/API/creation")
  print("signed_normal_cache_offline_reuse=true second_profile_fetches=0; cached config ignored and local-key rendered")
  let smartOnline=Harness();smartOnline.api.response=smartProfile
  let smartFirst=try await smartOnline.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.allExceptRu,writeHelperConfig:false,accountID:"owner")
  let smartFetches=smartOnline.api.profileCalls;smartOnline.api.mode="timeout"
  let smartCached=try await smartOnline.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.allExceptRu,writeHelperConfig:false,accountID:"owner")
  need(smartFirst.bypassRangesCount==2 && smartFirst.bypassDomainsCount==3 && smartCached.bypassRangesCount==2 && smartCached.bypassDomainsCount==3 && smartOnline.api.profileCalls==smartFetches,"smart signed cache preserves derived counts without refetch")
  print("smart signed cache reuse: fresh/cache count pair=2/3; fetches unchanged")
  smartOnline.cache.saved!.normalAuthorizationProfile=legacySmart;smartOnline.api.response=legacySmart;smartOnline.api.mode="working"
  let beforeLegacyMiss=smartOnline.api.profileCalls
  let legacyAfterCacheMiss=try await smartOnline.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.allExceptRu,writeHelperConfig:false,accountID:"owner")
  need(smartOnline.api.profileCalls==beforeLegacyMiss+1 && legacyAfterCacheMiss.bypassRangesCount==0 && legacyAfterCacheMiss.bypassDomainsCount==0,"old smart cache missing counts misses then fresh legacy retry")
  print("public smart cache: missing signed counts miss then one fresh legacy retry yields derived 0")
  var cacheRejects=0
  func badCache(_ label:String,_ record:PreparedTunnelCacheRecord,key:WireGuardKeyPair?=pair,installation:String?="installation",owner:String="owner",request:String="de",route:VpnRoutingMode = .fullTunnel)async {
   let h=Harness();h.cache.saved=record;h.api.mode="timeout";h.keyStore.existing=key;h.identityStore.existing=installation
   do {_=try await h.resolveProfile(accessToken:"fixture",locationId:request,routingMode:route,writeHelperConfig:true,accountID:owner);need(false,"invalid cache \(label)")}catch{}
   need(h.cache.writes==0 && h.cache.helperWrites==0 && h.api.profileCalls==1,"invalid cache must miss and never mutate helper/cache \(label)")
   cacheRejects+=1;print("cache rejected \(label): no writes; fresh request1, no timeout fallback")
  }
  var c=seed;c.normalAuthorizationProfile=nil;await badCache("legacy_missing_proof",c)
  c=seed;c.normalAuthorizationProfile=original;await badCache("legacy_unsigned_client_binding",c)
  c=seed;c.normalAuthorizationProfile!.authorization!.signatureBase64="A";await badCache("invalid_signature",c)
  c=seed;c.normalAuthorizationProfile!.authorization!.keyID="unknown";await badCache("unknown_anchor",c)
  c=seed;c.normalAuthorizationProfile!.revoked=true;await badCache("revoked",c)
  c=seed;c.normalAuthorizationProfile!.unchanged=true;await badCache("unchanged",c)
  c=seed;c.profileVersion=8;await badCache("version_metadata",c)
  c=seed;c.device.id="other";await badCache("device_id",c)
  c=seed;c.device.publicKey=k;await badCache("device_public_key",c)
  c=seed;c.device.externalDeviceId="other";await badCache("device_install",c)
  c=seed;c.device.status="revoked";await badCache("device_status",c)
  c=seed;c.normalAuthorizationProfile!.clientPublicKey=k;await badCache("outer_client_key",c)
  c=seed;c.normalAuthorizationProfile!.clientKeyEpoch=3;await badCache("outer_client_epoch",c)
  c=seed;c.normalAuthorizationProfile!.server="evil.example";await badCache("outer_endpoint",c)
  c=seed;c.normalAuthorizationProfile!.allowedIps=["10.0.0.0/8"];await badCache("outer_allowed_ips",c)
  c=seed;c.locationId="other";await badCache("request_metadata",c)
  c=seed;c.routingMode = .allExceptRu;await badCache("route_metadata",c)
  c=seed;c.cacheOwner=VPNProfileCacheOwner(accountID:"other",installationID:"installation");await badCache("owner_metadata",c)
  await badCache("actual_owner",seed,owner:"other")
  await badCache("actual_install",seed,installation:"other")
  await badCache("missing_existing_key",seed,key:nil)
  await badCache("changed_actual_key",seed,key:WireGuardKeyPair(privateKey:Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),publicKey:pair.publicKey,keyEpoch:2))
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["installation_id"]="other"};await badCache("signed_install",c)
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["client_public_key"]=k};await badCache("signed_client_key",c)
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["client_key_epoch"]=3};await badCache("signed_client_epoch",c)
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["requested_location_id"]="other"};await badCache("signed_request",c)
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["expires_at"]=iso.string(from:now.addingTimeInterval(-1))};await badCache("signed_expired",c)
  c=seed;c.normalAuthorizationProfile=try profile(signedBinding:true){$0["issued_at"]=iso.string(from:now.addingTimeInterval(-301))};c.fetchedAt=now.addingTimeInterval(9999);await badCache("signed_age_not_unsigned_fetchedAt",c)
  let forced=Harness();forced.cache.saved=seed;forced.api.response=signed
  _=try await forced.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,forceRefresh:true,writeHelperConfig:false,accountID:"owner")
  need(forced.api.profileCalls==1 && forced.cache.loads==0,"force refresh bypasses valid cache")
  let stale=Harness();stale.cache.saved=seed;var checks=0
  do {_=try await stale.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:true,accountID:"owner",validateCurrent:{checks+=1;if checks==2 {throw FixtureError.sessionChanged}});need(false,"stale cache session")}catch{}
  need(stale.api.profileCalls==0 && stale.cache.writes==0 && stale.cache.helperWrites==0,"cache late session guard not converted to fresh mutation")
  let removed=Harness();removed.cache.saved=seed;try removed.invalidateNormalCache(accountID:"owner")
  need(removed.cache.saved==nil && removed.cache.removes==1 && removed.cache.helperWrites==0,"owner invalidation no helper write")
  let removeFailure=Harness();removeFailure.cache.saved=seed;removeFailure.cache.failRemove=true
  do {try removeFailure.invalidateNormalCache(accountID:"owner");need(false,"remove failure")}catch{}
  removeFailure.api.mode="timeout"
  do {_=try await removeFailure.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:true,accountID:"owner");need(false,"reuse after failed removal")}catch{}
  need(removeFailure.api.profileCalls==1 && removeFailure.cache.helperWrites==0,"deletion failure must block reuse before fresh request")
  for cached in [false,true] {
   let h=Harness();h.cache.failRemove=true;h.cache.saved=cached ? seed:nil
   do {_=try await h.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:false,prevalidatedEntitlement:Entitlement(active:false,vpnAccess:false),accountID:"owner");need(false,"inactive entitlement accepted")}
   catch VPNProfileError.subscriptionInactive {} catch {need(false,"cache error masked subscriptionInactive")}
   need(h.api.profileCalls==0 && h.cache.helperWrites==0 && h.cache.removes==1,"inactive rejection must block/remove without helper")
  }
  let revoked=Harness();revoked.cache.failRemove=true;var revokedProfile=signed;revokedProfile.revoked=true;revoked.api.response=revokedProfile
  do {_=try await revoked.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,forceRefresh:true,writeHelperConfig:false,accountID:"owner");need(false,"revoked accepted")}
  catch VPNProfileError.deviceRevoked {} catch {need(false,"cache error masked deviceRevoked")}
  need(revoked.cache.removes==1 && revoked.cache.helperWrites==0,"revocation invalidation no helper")
  print("signed cache matrix PASS rejects=\(cacheRejects); force refresh/session/owner eviction/deletion-failure guard; no real cache/Keychain/API/helper/VPN mutation")
 }
}
'''.replace('ADMISSION',admission).replace('DEVICE',device).replace('BODIES',bodies).replace('CACHE_MODELS',cache_models).replace('CONTROL',control)
# No application/helper, OS preferences, Keychain, DNS, network, route/PF or VPN use.
tmp=Path(os.environ.get('TMPDIR','/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-21-native/tmp'));tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='normal-persistence-',dir=tmp) as p:
 d=Path(p);(d/'fixture.swift').write_text(harness)
 cmd=['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',str(S/'Models/VEXModels.swift'),str(S/'Services/NativeVPNProfileAuthorizationVerifier.swift'),str(S/'Services/NativeAwgBoolean.swift'),str(d/'fixture.swift'),'-o',str(d/'probe')]
 subprocess.run(cmd,check=True)
 subprocess.run(['rtk','proxy',str(d/'probe')],check=True)
