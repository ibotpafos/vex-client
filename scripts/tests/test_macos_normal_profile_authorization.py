#!/usr/bin/env python3
"""Actual pure normal-profile verifier, synthetic P-256 only; no I/O/tunnel API."""
from pathlib import Path
import os,subprocess,tempfile,sys
ROOT=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
S=ROOT/'macos-native/Sources/VEXNativeMac'
HARNESS=r'''
import Foundation
import CryptoKit
let now=Date(timeIntervalSince1970:1_800_000_000)
let key=P256.Signing.PrivateKey()
let der=key.publicKey.derRepresentation
func url64(_ data:Data)->String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
let iso=ISO8601DateFormatter()
func profile(_ change: (inout [String:Any])->Void = {_ in}, allowed:[String]=["0.0.0.0/0"]) throws -> ManagedVpnProfile {
    var policy:[String:Any]=["schema":"vex.native-vpn-profile.v1","user_id":"owner","device_id":"device","requested_location_id":"auto","assigned_location_id":"loc","routing_mode":"full_tunnel","profile_version":7,"issued_at":iso.string(from:now),"expires_at":iso.string(from:now.addingTimeInterval(3600)),"tunnel":["protocol":"wireguard","endpoint":"vpn.example:51820","assigned_ipv4":"10.0.0.2/32","server_public_key":"server","preshared_key":"psk","dns":["1.1.1.1"],"allowed_ips":allowed,"mtu":1420,"persistent_keepalive":55]]
    change(&policy)
    let payload=try JSONSerialization.data(withJSONObject:policy,options:[.sortedKeys])
    let signature=try key.signature(for:payload).derRepresentation
    let raw:[String:Any]=["device_id":"device","version":7,"protocol":"wireguard","server":"vpn.example","port":51820,"assigned_ipv4":"10.0.0.2/32","server_public_key":"server","preshared_key":"psk","dns":["1.1.1.1"],"allowed_ips":allowed,"expires_at":iso.string(from:now.addingTimeInterval(3600)),"config":"UNSIGNED_OPAQUE_CONFIG","bypass_ranges":["unsigned"],"bypass_domains":["unsigned.example"],"authorization":["algorithm":"ECDSA_P256_SHA256_DER","key_id":"k","payload_base64":url64(payload),"signature_base64":url64(signature)]]
    return try JSONDecoder().decode(ManagedVpnProfile.self,from:JSONSerialization.data(withJSONObject:raw))
}
let verifier=NativeVPNProfileAuthorizationVerifier(pinnedPublicKeyDER:["k":der])
func verify(_ p:ManagedVpnProfile,owner:String="owner",device:String="device",requested:String="auto",assigned:String="loc",route:String="full_tunnel",region:String?=nil,version:Int=7,anchors:[String:Data]=["k":der],requireCounts:Bool=false,at:Date=now) throws -> NativeVPNProfileAuthorizationVerifier.VerifiedNormalProfile {
    try NativeVPNProfileAuthorizationVerifier(pinnedPublicKeyDER:anchors).verifyNormalProfile(p,ownerAccountID:owner,managedDeviceID:device,requestedLocationID:requested,locationID:assigned,routingMode:route,bypassRegion:region,expectedProfileVersion:version,requireSignedBypassCounts:requireCounts,now:at)
}
var rejects=0
func rejected(_ label:String,_ body:()->Void) { body();print("rejected: \(label)");rejects+=1 }
func reject(_ label:String,_ p:ManagedVpnProfile,owner:String="owner",device:String="device",requested:String="auto",assigned:String="loc",route:String="full_tunnel",region:String?=nil,version:Int=7,anchors:[String:Data]=["k":der],at:Date=now) {
    do {_=try verify(p,owner:owner,device:device,requested:requested,assigned:assigned,route:route,region:region,version:version,anchors:anchors,at:at);fatalError("accepted \(label)")} catch { print("rejected: \(label)");rejects+=1 }
}
let original=try profile()
let clean=try verify(original)
precondition(clean.profile.authorization==nil && clean.profile.config==nil && clean.profile.bypassRanges==nil && clean.profile.bypassDomains==nil)
precondition(clean.mtu==1420 && clean.persistentKeepalive==55 && clean.profile.version==7)
print("normal valid signature: accepted; unsigned config/bypass metadata stripped; no rotation IDs")
reject("owner",original,owner:"other");reject("device",original,device:"other");reject("requested_location",original,requested:"other");reject("assigned_location",original,assigned:"other");reject("routing",original,route:"all_except_ru");reject("region",original,region:"ru");reject("expected_version",original,version:8);reject("zero_version",original,version:0);reject("empty_owner",original,owner:"");reject("empty_device",original,device:"");reject("empty_requested",original,requested:"");reject("empty_assigned",original,assigned:"");reject("expired",original,at:now.addingTimeInterval(3601));reject("missing_anchor",original,anchors:[:]);reject("unknown_key",original,anchors:["other":der])
var p=original;p.authorization=nil;reject("missing_auth",p)
p=original;p.authorization!.signatureBase64="A";reject("bad_signature",p)
p=original;p.authorization!.payloadBase64 += "A";reject("bad_payload",p)
p=original;p.authorization!.algorithm="none";reject("algorithm",p)
p=original;p.deviceId="other";reject("outer_device",p)
p=original;p.version=8;reject("outer_version",p)
p=original;p.revoked=true;reject("revoked",p)
p=original;p.unchanged=true;reject("unchanged_without_full_proof",p)
p=original;p.server="evil";reject("endpoint",p)
p=original;p.presharedKey="evil";reject("psk",p)
p=original;p.dns=["8.8.8.8"];reject("dns",p)
p=original;p.allowedIps=["10.0.0.0/8"];reject("route_geometry",p)
p=original;p.expiresAt=iso.string(from:now.addingTimeInterval(3601));reject("outer_expiry",p)
reject("signed_schema",try profile{$0["schema"]="other"})
reject("signed_requested_location",try profile{$0["requested_location_id"]="other"})
reject("missing_signed_request",try profile{$0.removeValue(forKey:"requested_location_id")})
reject("signed_assigned_location",try profile{$0["assigned_location_id"]="other"})
reject("future_issued",try profile{$0["issued_at"]=iso.string(from:now.addingTimeInterval(1))})
reject("signed_policy_version",try profile{$0["routing_policy_version"]="other"})
// Explicit split policy retains signed geometry only, never unsigned domain/range metadata.
var split=try profile({$0["routing_mode"]="all_except_ru";$0["bypass_region"]="ru";$0["routing_policy_version"]="r1"},allowed:["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"]);split.routingPolicyVersion="r1"
let signedSplit=try verify(split,route:"all_except_ru",region:"ru")
split=try profile({$0["routing_mode"]="all_except_ru";$0["bypass_region"]="ru";$0["routing_policy_version"]="r1";$0["bypass_ranges_count"]=2;$0["bypass_domains_count"]=3},allowed:["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"]);split.routingPolicyVersion="r1"
let countedSplit=try verify(split,route:"all_except_ru",region:"ru",requireCounts:true)
precondition(countedSplit.bypassRangesCount==2 && countedSplit.bypassDomainsCount==3 && countedSplit.profile.allowedIps==["0.0.0.0/1","128.0.0.0/2","192.0.0.0/3","224.0.0.0/4"] && countedSplit.profile.bypassRanges==nil && countedSplit.profile.bypassDomains==nil)
for change in [{ (p: inout [String:Any]) in _ = p.removeValue(forKey:"bypass_ranges_count") }, { (p: inout [String:Any]) in _ = p.removeValue(forKey:"bypass_domains_count") }, { (p: inout [String:Any]) in p["bypass_ranges_count"] = -1 }, { (p: inout [String:Any]) in p["bypass_domains_count"] = "3" }, { (p: inout [String:Any]) in p["bypass_ranges_count"] = NSDecimalNumber(string:"9223372036854775808") }] {
 var malformed=try profile(change); malformed.routingPolicyVersion="r1"
 do {_=try verify(malformed,route:"all_except_ru",region:"ru",requireCounts:true);fatalError("accepted malformed counts")} catch {}
}
do {_=try verify(try profile{$0["bypass_ranges_count"]=1;$0["bypass_domains_count"]=1});fatalError("accepted full-tunnel counts")} catch {}
var fullDefaultSmart=try profile{$0["routing_mode"]="all_except_ru";$0["bypass_region"]="ru";$0["routing_policy_version"]="r1";$0["bypass_ranges_count"]=1;$0["bypass_domains_count"]=1};fullDefaultSmart.routingPolicyVersion="r1"
do {_=try verify(fullDefaultSmart,route:"all_except_ru",region:"ru",requireCounts:true);fatalError("accepted smart full default")} catch {}
print("signed bypass counts: split pair survives verification; unsigned outer lists stripped; missing/partial/negative/noninteger/overflow and full-tunnel nonzero rejected; legacy full omission=0")
print("normal verifier matrix: PASS rejects=\(rejects); signed split geometry retained, unsigned metadata stripped; helper/cache/keychain/network calls=0")
'''
with tempfile.TemporaryDirectory(prefix='normal-profile-verifier-') as p:
    d=Path(p);(d/'main.swift').write_text(HARNESS)
    subprocess.run(['rtk','proxy','swiftc',str(S/'Models/VEXModels.swift'),str(S/'Services/NativeVPNProfileAuthorizationVerifier.swift'),str(d/'main.swift'),'-o',str(d/'verify')],check=True)
    subprocess.run(['rtk','proxy',str(d/'verify')],check=True)
