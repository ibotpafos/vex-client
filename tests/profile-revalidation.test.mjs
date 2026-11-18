import assert from 'node:assert/strict';
import test from 'node:test';
import {profileRevalidationOptions,canRevalidateDevice} from '../src/vpn/profileRevalidation.ts';
import vpnModuleLoader from './vpn-module-loader.cjs';
const device={id:'device',publicKey:'public',keyEpoch:2,status:'active',assignedIpv4:'10.0.0.2'};
const profile={config:'Address = 10.0.0.2/32',device,locationId:'de',routingMode:'smart',profileVersion:7};
test('conditional profile reuse requires matching location, routing, version and address',()=>{
 assert.equal(profileRevalidationOptions(profile,'de','smart').knownVersion,7);
 for(const changed of [{locationId:'fi'},{routingMode:'full'},{rotationRequired:true},{profileVersion:0},{profileVersion:Number.MAX_SAFE_INTEGER+1},{config:'Address = 10.0.0.3/32'}])
  assert.deepEqual(profileRevalidationOptions({...profile,...changed},'de','smart'),{});
 for(const changed of [{id:'replacement'},{publicKey:'rotated'},{keyEpoch:3}])assert.equal(canRevalidateDevice(device,{...device,...changed},'public'),false);
 for(const keyEpoch of [NaN,Infinity,-1,1.5,Number.MAX_SAFE_INTEGER+1])assert.equal(canRevalidateDevice({...device,keyEpoch},{...device,keyEpoch},'public'),false);
});

test('managed profile revalidation always reaches API and rejects revocation or stale identity',async()=>{
 for(const scenario of ['unchanged','revoked','replacement','epoch','repair']){
  const queries=[];
  const account = vpnModuleLoader.accountFixture({owner:'fixture-owner',deviceId:'device',externalDeviceId:'runtime'});
  const current = {...account.device, assignedIpv4: device.assignedIpv4,
    ...(scenario==='replacement'?{id:'replacement'}:{}), ...(scenario==='epoch'?{keyEpoch:3}:{})};
  // A legacy cache lacks installation metadata: the real selector must read /devices.
  const cached = {...profile, device:{...device, publicKey:account.keyPair.publicKey}};
  const {preparedTunnel: run} = vpnModuleLoader.loadWithBindings('src/api/vpn.ts', 'preparedTunnel', {
    Platform:{OS:'android'}, supportsNativeRoutingPolicy:()=>false,
    SecureStore:{getItemAsync:async key=>account.saved.get(key)??null,
      setItemAsync:async()=>assert.fail('revalidation must not mutate account storage')},
    clientVersionHeaders:async()=>({}), getOrCreateDeviceId:async()=> 'runtime',
    jsonRequest:async path=>{
      if(path==='/v1/devices') return [{id:current.id,user_id:current.userId,status:current.status,
        public_key:current.publicKey,psk_epoch:current.keyEpoch,assigned_ipv4:current.assignedIpv4,
        external_device_id:current.externalDeviceId,platform:current.platform,protocol:current.protocol,
        provisioning_mode:current.provisioningMode,client_key_ownership:current.clientKeyOwnership}];
      assert.ok(path.startsWith('/v1/vpn/profile?'),path);
      queries.push(path);return scenario==='revoked'?{revoked:true}:{unchanged:true,version:7};
    },
    rawRequest:async()=>assert.fail('revalidation must not authorize legacy config issuance'),
  });
  const options={...(scenario==='repair'?{}:profileRevalidationOptions(cached,'de','smart')),
    locationId:'de',routingMode:'smart',userId:'fixture-owner',isCurrentSessionOperation:()=>true};
  const client={platform:'android',deviceName:'Fixture',idempotencyPrefix:'fixture'};
  if(scenario==='unchanged')assert.equal((await run('token',client,options)).config,profile.config);
  else await assert.rejects(run('token',client,options),scenario==='revoked'?/Устройство отключено администратором/:/локальный cache пуст/);
  assert.equal(queries.length,1,'must validate with authoritative endpoint');
  assert.equal(queries[0].includes('known_version=7'),scenario==='unchanged'||scenario==='revoked');
 }
});
