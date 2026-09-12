import fs from 'node:fs';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';
import {profileRevalidationOptions,canRevalidateDevice} from '../src/vpn/profileRevalidation.ts';
const device={id:'device',publicKey:'public',keyEpoch:2,status:'active',assignedIpv4:'10.0.0.2'};
const profile={config:'Address = 10.0.0.2/32',device,locationId:'de',routingMode:'smart',profileVersion:7};
test('conditional profile reuse requires matching location, routing, version and address',()=>{
 assert.equal(profileRevalidationOptions(profile,'de','smart').knownVersion,7);
 for(const changed of [{locationId:'fi'},{routingMode:'full'},{rotationRequired:true},{profileVersion:0},{config:'Address = 10.0.0.3/32'}])
  assert.deepEqual(profileRevalidationOptions({...profile,...changed},'de','smart'),{});
 for(const changed of [{id:'replacement'},{publicKey:'rotated'},{keyEpoch:3}])assert.equal(canRevalidateDevice(device,{...device,...changed},'public'),false);
});

test('managed profile revalidation always reaches API and rejects revocation or stale identity',async()=>{
 const source=stripTypeScriptTypes(fs.readFileSync('src/api/vpn.ts','utf8')).replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm,'').replace(/\bexport /g,'');
 for(const scenario of ['unchanged','revoked','replacement','epoch','repair']){
  const queries=[];
  const current={...device,...(scenario==='replacement'?{id:'replacement'}:{}),...(scenario==='epoch'?{keyEpoch:3}:{})};
  const stubs={clientVersionHeaders:async()=>({}),getOrCreateWireGuardKeyPair:async()=>({publicKey:'public'}),getOrCreateDeviceId:async()=> 'runtime',nativeVpnDeviceForClient:devices=>devices.length?undefined:current,
   withManagedProfileAWGCapability:q=>q,defaultVpnRoutingMode:'smart',defaultVpnRoutingPolicyVersion:'v1',resolvedVpnBypassRegion:()=>'',requireVpnLocationId:x=>x,
   canRevalidateDevice,jsonRequest:async path=>{if(path==='/v1/devices')return [];queries.push(path);return scenario==='revoked'?{revoked:true}:{unchanged:true,version:7};}};
  const run=new Function(...Object.keys(stubs),source+';return managedVpnProfile;')(...Object.values(stubs));
  const options=scenario==='repair'?{locationId:'de'}:{...profileRevalidationOptions(profile,'de','smart'),locationId:'de'};
  if(scenario==='unchanged')assert.equal((await run('token',{},options)).config,profile.config);
  else await assert.rejects(run('token',{},options));
  assert.equal(queries.length,1,'must validate with authoritative endpoint');
  assert.equal(queries[0].includes('known_version=7'),scenario==='unchanged'||scenario==='revoked');
 }
});
