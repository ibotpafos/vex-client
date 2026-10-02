#!/usr/bin/env python3
"""Reuse signed-normal fixture; actual readonly service with inert API/cache ports."""
from pathlib import Path
import os,sys,subprocess,tempfile
ROOT=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
fixture_path=Path(__file__).with_name('test_macos_normal_profile_persistence.py')
ns={'__file__':str(fixture_path)}
exec(compile(fixture_path.read_text().split('# No application/helper')[0],str(fixture_path),'exec'),ns)
method=ns['extract']('refreshRegisteredNormalProfile')
h=ns['harness'].replace(' func admit(',method+'\n func admit(',1)
api=r'''
 var readonlyCalls=0
 func readOnlyManagedVpnProfile(accessToken:String,deviceId:String,locationId:String,routingMode:VpnRoutingMode,bypassRegion:String?)async throws->ManagedVpnProfile {
  readonlyCalls+=1;await Task.yield();after?("readonly");return response!
 }
'''
h=h.replace('@MainActor final class FakeAPI {','@MainActor final class FakeAPI {'+api,1)
h=h[:h.index('@main struct Main')]+r'''
@main struct Main {
 @MainActor static func main()async throws {
  var d=device;d.protocol="amneziawg"
  let signed=try profile(signedBinding:true)
  let h=Harness();h.api.response=signed
  try h.invalidateNormalCache(accountID:"owner")
  _=try await h.refreshRegisteredNormalProfile(accessToken:"fixture",device:d,locationId:"de",routingMode:.fullTunnel,accountID:"owner")
  let owner=VPNProfileCacheOwner(accountID:"owner",installationID:"installation")!
  need(h.api.readonlyCalls==1 && h.api.profileCalls==0 && h.cache.writes==1 && h.cache.helperWrites==0 && h.cache.loads==0 && h.identityStore.reads==0 && h.keyStore.reads==0 && !h.normalCacheReuse.isBlocked(owner),"readonly fetch/write/unblock without creation or old endpoint")
  need(h.cache.saved!.normalAuthorizationProfile==signed,"persist original signed proof")
  var rejects=0
  func reject(_ label:String,_ p:ManagedVpnProfile,dev:VpnDevice=d,install:String?="installation",key:WireGuardKeyPair?=pair,late:Bool=false,expectedFetch:Int=1)async {
   let x=Harness();x.api.response=p;x.identityStore.existing=install;x.keyStore.existing=key
   var current=true;x.api.after={if late && $0=="readonly" {current=false}}
   do {_=try await x.refreshRegisteredNormalProfile(accessToken:"fixture",device:dev,locationId:"de",routingMode:.fullTunnel,accountID:"owner",validateCurrent:{if !current {throw FixtureError.sessionChanged}});need(false,"accepted \(label)")}catch{}
   need(x.api.readonlyCalls==expectedFetch && x.api.profileCalls==0 && x.cache.writes==0 && x.cache.helperWrites==0 && x.identityStore.reads==0 && x.keyStore.reads==0,"rejected readonly writes \(label)")
   rejects+=1
  }
  await reject("legacy unsigned binding",try profile())
  var p=signed;p.revoked=true;await reject("revoked",p)
  p=signed;p.rotationRequired=true;await reject("rotation",p)
  p=signed;p.unchanged=true;await reject("unchanged",p)
  p=signed;p.authorization!.signatureBase64="A";await reject("signature",p)
  await reject("wrong signed install",try profile(signedBinding:true){$0["installation_id"]="other"})
  await reject("wrong signed key",try profile(signedBinding:true){$0["client_public_key"]=k})
  await reject("wrong signed epoch",try profile(signedBinding:true){$0["client_key_epoch"]=3})
  await reject("late session",signed,late:true)
  await reject("missing local install",signed,install:nil,expectedFetch:0)
  await reject("different local install",signed,install:"other",expectedFetch:0)
  await reject("missing existing key",signed,key:nil,expectedFetch:0)
  var wrong=d;wrong.status="revoked";await reject("local revoked",signed,dev:wrong,expectedFetch:0)
  wrong=d;wrong.publicKey=k;await reject("local public key",signed,dev:wrong,expectedFetch:0)
  wrong=d;wrong.platform="android";await reject("foreign platform",signed,dev:wrong,expectedFetch:0)
  let superseded=Harness();superseded.api.response=signed
  superseded.api.after={if $0=="readonly" {try! superseded.invalidateNormalCache(accountID:"owner")}}
  do {_=try await superseded.refreshRegisteredNormalProfile(accessToken:"fixture",device:d,locationId:"de",routingMode:.fullTunnel,accountID:"owner");need(false,"superseded readonly fetch")}catch{}
  need(superseded.cache.writes==0 && superseded.normalCacheReuse.isBlocked(owner),"new invalidation remains blocked; old response cannot save/unblock")
  let resolver=Harness();resolver.api.response=signed;resolver.api.after={if $0=="profile" {try! resolver.invalidateNormalCache(accountID:"owner")}}
  do {_=try await resolver.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:true,accountID:"owner");need(false,"superseded normal resolver")}catch{}
  need(resolver.cache.writes==0 && resolver.cache.helperWrites==0 && resolver.normalCacheReuse.isBlocked(owner),"normal resolver also fenced by push epoch")
  let early=Harness();early.api.response=signed;early.api.after={if $0=="entitlement" {try! early.invalidateNormalCache(accountID:"owner")}}
  do {_=try await early.resolveProfile(accessToken:"fixture",locationId:"de",routingMode:.fullTunnel,writeHelperConfig:true,accountID:"owner");need(false,"superseded entitlement")}catch{}
  need(early.keyStore.reads==0 && early.api.profileCalls==0 && early.cache.helperWrites==0,"epoch checked before key creation after entitlement await")
  print("readonly signed normal matrix PASS rejects=\(rejects); actual service/verifier/models/CryptoKit/AWG; cache1 helper0 identity-create0 old-api0; no real cache/API/helper/VPN use")
 }
}
'''
tmp=Path(os.environ.get('TMPDIR','/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-22-native/tmp'));tmp.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='readonly-normal-',dir=tmp) as raw:
    d=Path(raw);(d/'main.swift').write_text(h)
    S=ns['S']
    subprocess.run(['rtk','proxy','swiftc','-swift-version','5','-parse-as-library',str(S/'Models/VEXModels.swift'),str(S/'Services/NativeVPNProfileAuthorizationVerifier.swift'),str(S/'Services/NativeAwgBoolean.swift'),str(d/'main.swift'),'-o',str(d/'probe')],check=True)
    raise SystemExit(subprocess.run(['rtk','proxy',str(d/'probe')]).returncode)
