import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { profileRevalidationOptions, canRevalidateDevice } from '../src/vpn/profileRevalidation.ts';
import { nativeVpnDeviceForClient } from '../src/vpn/nativeDeviceSelection.ts';
import { ApiRequestError } from '../src/api/error.ts';

const device = {id:'device', publicKey:'public', keyEpoch:2, status:'active', assignedIpv4:'10.0.0.2', externalDeviceId:'runtime', protocol:'amneziawg', provisioningMode:'managed_native', clientKeyOwnership:'client'};
const cached = {config:'Address = 10.0.0.2/32', device, locationId:'de', routingMode:'smart', profileVersion:7};
const confirmed = {unchanged:true, version:7, revoked:false, device_id:'device', client_public_key:'public', client_key_epoch:2};
const deferred = () => { let resolve; const promise = new Promise(r => {resolve=r;}); return {promise, resolve}; };
const tick = () => new Promise(resolve => setImmediate(resolve));

function load(sourcePath, exported, stubs) {
  const source = stripTypeScriptTypes(fs.readFileSync(sourcePath, 'utf8')).replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm,'').replace(/\bexport /g,'');
  return new Function(...Object.keys(stubs), source+`;return ${exported};`)(...Object.values(stubs));
}

function managedHarness({response = confirmed, current = device, key = {publicKey:'public'}, headers = async () => ({}), list, options = {}} = {}) {
  const requests = [];
  const run = load('src/api/vpn.ts', 'managedVpnProfile', {
    clientVersionHeaders:headers, getOrCreateWireGuardKeyPair:async()=>typeof key === 'function' ? key() : key, getOrCreateDeviceId:async()=> 'runtime', nativeVpnDeviceForClient,
    withManagedProfileAWGCapability:q=>q, defaultVpnRoutingMode:'smart', defaultVpnRoutingPolicyVersion:'v1', resolvedVpnBypassRegion:()=>'', requireVpnLocationId:x=>x,
    canRevalidateDevice, ApiRequestError, jsonRequest:async path=> {
      requests.push(path);
      if(path==='/v1/devices') return list ? list() : [{id:current.id, public_key:current.publicKey, psk_epoch:current.keyEpoch, status:current.status,
        assigned_ipv4:current.assignedIpv4, external_device_id:current.externalDeviceId, protocol:current.protocol,
        provisioning_mode:current.provisioningMode, client_key_ownership:current.clientKeyOwnership}];
      if(response instanceof Error) throw response;
      return typeof response === 'function' ? response(requests) : response;
    },
  });
  return {requests, run:() => run('token', {}, {...profileRevalidationOptions(cached,'de','smart'), locationId:'de', ...options})};
}

test('confirmed cached profile needs one authoritative request and no device-list round trip', async () => {
  const h = managedHarness();
  const result = await h.run();
  assert.equal(result.config, cached.config);
  assert.equal(h.requests.length, 1);
  assert.match(h.requests[0], /^\/v1\/vpn\/profile\?/);
  assert.match(h.requests[0], /known_version=7/);
});

test('independent native identity preparation overlaps header preparation', async () => {
  const headers = deferred();
  let keyStarted = false;
  const h = managedHarness({headers:()=>headers.promise, key:()=>{keyStarted=true; return {publicKey:'public'};}});
  const pending = h.run();
  await tick();
  const overlapped = keyStarted;
  headers.resolve({});
  await pending;
  assert.equal(overlapped, true);
});

test('cached profile remains gated by the live authorization response', async () => {
  const gate = deferred();
  const h = managedHarness({response:() => gate.promise});
  let resolved = false;
  const pending = h.run().then(value => {resolved = true; return value;});
  await tick();
  assert.equal(resolved, false);
  gate.resolve({...confirmed, revoked:true});
  await assert.rejects(pending, /администратором/);
});

test('authorization errors never fall back to local or alternate device access', async () => {
  for (const status of [401,403]) {
    const error = new ApiRequestError('denied', {status});
    const h = managedHarness({response:error});
    await assert.rejects(h.run(), err => err === error);
    assert.equal(h.requests.length, 1);
    assert.ok(!h.requests.includes('/v1/devices'));
  }
});

test('deleted cached device can be rediscovered after a profile 404', async () => {
  const h = managedHarness({response:requests=>{
    if (!requests.includes('/v1/devices')) throw new ApiRequestError('not found',{status:404});
    return confirmed;
  }});
  assert.equal((await h.run()).config, cached.config);
  assert.ok(h.requests.includes('/v1/devices'));
});

test('changed routing profile with matching key is delivered without redundant lookup or issuance', async () => {
  const h = managedHarness({response:{...confirmed,unchanged:false,version:8,config:'Address = 10.0.0.3/32',assigned_ipv4:'10.0.0.3/32'}});
  const result = await h.run();
  assert.equal(result.profileVersion,8);
  assert.equal(result.device.assignedIpv4,'10.0.0.3/32');
  assert.equal(h.requests.length,1);
});

test('missing key identity and changed device or epoch fall back to current device lookup', async () => {
  for (const response of [
    {unchanged:true, version:7}, {...confirmed, client_public_key:'different'}, {...confirmed, client_key_epoch:3},
    {...confirmed, device_id:'replacement'}, {...confirmed, version:8},
  ]) {
    const h = managedHarness({response: requests => requests.includes('/v1/devices') ? confirmed : response});
    assert.equal((await h.run()).config, cached.config);
    assert.ok(h.requests.includes('/v1/devices'));
  }
});

test('unconditional recovery still performs current device lookup and does not send known_version', async () => {
  const h = managedHarness({options:{cachedConfig:undefined,cachedDevice:undefined,knownVersion:undefined}});
  await assert.rejects(h.run(), /cache пуст/);
  assert.equal(h.requests[0], '/v1/devices');
  assert.doesNotMatch(h.requests.at(-1), /known_version=/);
});

test('API profile delivery does not wait for duplicate secure-cache persistence', async () => {
  const storage = deferred();
  let writes = 0;
  const run = load('src/vpn/profile.ts','resolveVpnProfile', {
    defaultVpnRoutingMode:'smart', defaultVpnBypassRegion:'ru', defaultVpnRoutingPolicyVersion:'v1',
    requireVpnLocationId:x=>x, profileRevalidationOptions, vpnProfileAddressMatchesDevice:()=>true,
    hasPaidEntitlement:()=>true, preparedTunnel:async()=>({...cached, config:cached.config}), runProfileRequest:fn=>fn(),
    saveHotVpnProfile:()=>{writes++; return storage.promise;},
  });
  let resolved = false;
  const pending = run('token', {active:true}, 'de', {forceRefresh:true, userId:'user'}).then(profile => {resolved=true; return profile;});
  await tick();
  const completedBeforeStorage = resolved;
  storage.resolve(null);
  await pending;
  assert.equal(completedBeforeStorage, true, 'ready profile must not wait for secure-store IO');
  assert.equal(writes, 0, 'the owning hook already persists this profile');
});

test('background profile refresh revalidates the cached version before issuing another peer', async () => {
  const effects = [];
  const resolutions = [];
  const queryClient = {getQueryData:()=>cached, setQueryData:()=>{}, fetchQuery:({queryFn})=>queryFn()};
  const run = load('src/vpn/useVpnProfileState.ts', 'useVpnProfileState', {
    useRef:current=>({current}), useState:initial=>[initial,()=>{}], useMemo:fn=>fn(), useCallback:fn=>fn, useEffect:fn=>effects.push(fn),
    useQueryClient:()=>queryClient, resolveVpnProfile:async(...args)=>{resolutions.push(args); return cached;},
    hydrateHotVpnProfilesToQueryCache:async()=>[], saveHotVpnProfile:async()=>null,
  });
  run({accessToken:'token', userId:'user', hasVpnAccess:true, knownEntitlement:{active:true}, selectedLocationId:'de', routingMode:'smart',
    realtimeConnected:true, profileRefreshMs:60_000, requestVpnPermission:async()=>true,
    onDeviceRevoked:async()=>{}, onProfileRotationRequired:()=>{}, onSubscriptionRequired:()=>{}});
  const cleanups = effects.map(fn=>fn());
  await tick();
  cleanups.forEach(fn=>fn?.());
  assert.equal(resolutions.length, 1);
  assert.equal(resolutions[0][3].revalidateProfile, cached);
});

test('connection samples include detailed profile stages only for the current online resolution', () => {
  const samples = load('src/vpn/connectFlow.ts', 'vpnConnectTimingSamples', {});
  const resolutionTiming = {startedAtMs:110,localPrepareMs:3,deviceLookupMs:0,profileRequestMs:45,queueWaitMs:7};
  const input = {endpointAttempts:[],tapStartedAt:100,nativeStartMs:200,interfaceUpMs:250,verificationCompletedMs:300,
    profile:{...cached,source:'api',resolutionTiming}};
  const current = samples(input);
  assert.equal(current.profile_local_prepare_ms,3);
  assert.equal(current.profile_device_lookup_ms,0);
  assert.equal(current.profile_request_ms,45);
  assert.equal(current.profile_queue_wait_ms,7);
  for (const profile of [{...input.profile,source:'local'}, {...input.profile,resolutionTiming:{...resolutionTiming,startedAtMs:50}}]) {
    assert.equal(samples({...input,profile}).profile_request_ms,undefined,'old cached timings must not be attributed to a new connection');
  }
});
