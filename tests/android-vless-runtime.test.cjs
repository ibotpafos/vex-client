const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const test = require('node:test');
const root = path.resolve(__dirname, '..');

// Execute production modules against isolated adapters: no tunnel, account or network changes.
function load(file, dependencies = {}, globals = {}) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  vm.runInNewContext(code, { exports, Error, Date, JSON, Promise, setTimeout, clearTimeout,
    require: name => { assert.ok(Object.hasOwn(dependencies, name), `unexpected import ${name}`); return dependencies[name]; }, ...globals });
  return exports;
}
function raw(file, symbol, bindings) {
  const source = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText.replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm, '').replace(/\bexport /g, '');
  return new Function(...Object.keys(bindings), source + `;return ${symbol};`)(...Object.values(bindings));
}
const pure = name => load(`src/vpn/${name}.ts`);
const transport = pure('transport');
const { parseVlessProfileResponse } = load('src/api/vlessProfile.ts');
const { ApiRequestError } = load('src/api/error.ts');
const verification = pure('vpnStatusVerification');
const { waitForVerifiedVpnConnection } = pure('connectVerification');
const scheduleVpnVerificationTimeout = (delayMs, callback) => {
  const timer = setTimeout(callback, delayMs);
  return () => clearTimeout(timer);
};
const { assessNativeTunnelHealth } = pure('nativeTunnelHealth');
const sessionOperation = pure('sessionOperation');
const paid = { active: true, vpnAccess: true };
const connectionId = '12345678-1234-1234-1234-123456789abc';
const otherConnectionId = 'abcdef12-1234-1234-1234-123456789abc';
const config = JSON.stringify({ outbounds: [{ protocol: 'vless', streamSettings: { network: 'xhttp', security: 'tls', tlsSettings: {serverName:'fixture.example'} } }] });
const response = () => ({ schema_version: 1, protocol: 'vless', device_id: 'device', location_id: 'de', route_id: 'route-1', expires_at: new Date(Date.now() + 60_000).toISOString(), config });
const device = { id: 'device', userId: 'owner', status: 'active', externalDeviceId: 'physical', provisioningMode: 'managed_native', clientKeyOwnership: 'client', platform: 'android', protocol: 'amneziawg' };
const vlessProfile = () => ({ transport: 'vless', config, locationId: 'de', device, expiresAt: response().expires_at, source: 'api', entitlement: paid, routingMode: 'full_tunnel' });

test('VLESS response is strictly device/location/version/expiry bound', () => {
  assert.equal(parseVlessProfileResponse(response(), 'device', 'de').config, config);
  for (const patch of [{device_id:'other'}, {location_id:'fi'}, {schema_version:2}, {protocol:'amneziawg'}, {route_id:''},
    {expires_at:'invalid'}, {expires_at:'2020-01-01T00:00:00Z'}, {config:'vless://secret'}, {config:'{}'}, {config:JSON.stringify({padding:'Я'.repeat(140_000),outbounds:JSON.parse(config).outbounds})},
    {config:JSON.stringify({outbounds:[...JSON.parse(config).outbounds,...JSON.parse(config).outbounds]})},
    {config:JSON.stringify({outbounds:[{...JSON.parse(config).outbounds[0],streamSettings:{network:'xhttp',security:'tls',tlsSettings:{allowInsecure:true}}}]})},
    {config:JSON.stringify({outbounds:[{protocol:'vless',streamSettings:{network:'tcp',security:'none'}}]})}]) {
    assert.throws(() => parseVlessProfileResponse({...response(), ...patch}, 'device', 'de'), /VLESS-профиль/);
  }
});

test('VLESS cache keys are separate while old AWG cache keys retain their contract', () => {
  assert.deepEqual([...transport.vpnProfileQueryKey('token','de','full_tunnel')], ['vpn-profile','token','de','full_tunnel']);
  assert.notDeepEqual([...transport.vpnProfileQueryKey('token','de','full_tunnel','vless')], [...transport.vpnProfileQueryKey('token','de','full_tunnel')]);
  assert.equal(transport.normalizeVpnTransport(undefined), 'amneziawg');
});

function nativeHarness({ support = true, status = { state:'connected', rxBytes:0, txBytes:0, transport:'vless', verified:true, connectionId, verificationEpochMillis:Date.now() } } = {}) {
  const calls = [];
  const module = { connect: async () => { calls.push('awg'); return status; }, status:async()=>status };
  if (support) module.connectVless = async (...args) => { calls.push(args); return status; };
  const native = load('src/native/vexVpn.ts', {
    'react-native': { NativeModules:{VexVpn:module}, Platform:{OS:'android'} }, expo:{},
    '@/vpn/disconnectRecovery': {}, '@/vpn/vpnStatusVerification':verification, '@/vpn/nativeRoutingPolicy':{nativeRoutingParameters:()=>''},
  });
  return { calls, native };
}

test('VLESS bridge admission never falls back to AWG on an old native binary', async () => {
  const h = nativeHarness({support:false});
  assert.equal(h.native.supportsNativeVless(), false);
  await assert.rejects(h.native.connectVpn(config,{transport:'vless'}), /обновите/);
  assert.equal(h.calls.length, 0);
});

test('VLESS uses its own full-tunnel bridge and preserves explicit per-app selection', async () => {
  const h = nativeHarness();
  const status = await h.native.connectVpn(config,{transport:'vless', applicationRoutingMode:'selected',selectedApplications:['private.package']});
  assert.equal(status.verified,true);
  assert.equal(status.latestHandshakeEpochMillis,undefined);
  assert.deepEqual(JSON.parse(JSON.stringify(h.calls[0])),[config,true,JSON.stringify({mode:'full_tunnel'}),['private.package'],true]);
});

test('engine ready, bytes and WireGuard handshake are insufficient VLESS proof', async () => {
  for (const status of [
    {verified:false,connectionId,verificationEpochMillis:500}, {verified:true,connectionId},
    {verified:true,connectionId:'invalid',verificationEpochMillis:500},
  ]) {
    const h = nativeHarness({status:{state:'connected',transport:'vless',rxBytes:100,txBytes:100,latestHandshakeEpochMillis:500,...status}});
    const normalized = await h.native.getVpnStatus({fresh:true});
    assert.equal(normalized.verified,false);
    assert.equal(normalized.latestHandshakeEpochMillis,undefined);
  }
});

test('connect verification accepts only fresh native VLESS proof from this connection', async () => {
  const pending = { state:'connected',transport:'vless',verified:false,connectionId,rxBytes:0,txBytes:0 };
  const good = {...pending,verified:true,connectionId,verificationEpochMillis:500};
  for (const changed of [{connectionId:'ffffffff-1234-1234-1234-123456789abc'}, {connectionId:otherConnectionId}, {verificationEpochMillis:399}, {verificationEpochMillis:1001}, {transport:'amneziawg',latestHandshakeEpochMillis:500}]) {
    const stale = {...good,...changed};
    await assert.rejects(waitForVerifiedVpnConnection(stale,async()=>stale,{transport:'vless',expectedConnectionId:connectionId,previousConnectionId:otherConnectionId,minimumVerificationEpochMillis:400,now:()=>1000,attempts:1}), /timed out/);
  }
  assert.equal((await waitForVerifiedVpnConnection(pending,async()=>good,{transport:'vless',expectedConnectionId:connectionId,previousConnectionId:otherConnectionId,minimumVerificationEpochMillis:400,now:()=>1000,attempts:1})).connectionId,connectionId);
});

test('VLESS health ignores WG peer usage and requires fresh owned native data-plane proof', () => {
  const status={state:'connected',transport:'vless',verified:true,connectionId,verificationEpochMillis:1000};
  const input={transport:'vless',status,nowMs:2000,staleHandshakeSeconds:180,deviceUsage:{connected:false,connectionStatus:'missing_peer',secondsSinceHandshake:999999}};
  assert.equal(assessNativeTunnelHealth(input).healthy,true);
  for (const changed of [{verified:false},{verificationEpochMillis:0},{verificationEpochMillis:3000},{connectionId:'invalid'}]) {
    assert.equal(assessNativeTunnelHealth({...input,status:{...status,...changed}}).healthy,false);
  }
  assert.equal(assessNativeTunnelHealth({...input,status:undefined}).healthy,false);
  assert.equal(assessNativeTunnelHealth({...input,status:{...status,transport:'amneziawg',latestHandshakeEpochMillis:2000}}).healthy,false);
  assert.equal(assessNativeTunnelHealth({...input,nowMs:200_000}).healthy,false);
});

function profileHarness({available=true,vless=async()=>({device,config,expiresAt:response().expires_at,routeId:'route-1'})}={}) {
  const calls=[];
  const resolve=raw('src/vpn/profile.ts','resolveVpnProfile',{
    supportsNativeVless:()=>available, requireVpnLocationId:value=>value, defaultVpnRoutingMode:'full_tunnel',
    defaultVpnBypassRegion:'none',defaultVpnRoutingPolicyVersion:'v1', entitlement:async()=>paid,hasPaidEntitlement:value=>value?.active,
    runProfileRequest:operation=>operation(),preparedVlessTunnel:async(...args)=>{calls.push('vless');return vless(...args);},
    preparedTunnel:async()=>{calls.push('awg');return {config:'Address = 10.0.0.2/32',device};},
    profileRevalidationOptions:()=>({}),vpnProfileAddressMatchesDevice:()=>true,...sessionOperation,
  });
  return {calls,resolve};
}

test('a failed explicitly selected VLESS profile never silently requests AWG', async () => {
  for (const status of [404,503]) {
    const error=Object.assign(new Error('profile unavailable'),{status});
    const h=profileHarness({vless:async()=>{throw error;}});
    await assert.rejects(h.resolve('token',paid,'de',{transport:'vless'}),caught=>caught===error);
    assert.deepEqual(h.calls,['vless']);
  }
  const h=profileHarness({available:false});
  await assert.rejects(h.resolve('token',paid,'de',{transport:'vless'}),/обновите/);
  assert.deepEqual(h.calls,[]);
});

test('protocol switching does not reuse VLESS credentials as an AWG profile', async () => {
  const h=profileHarness();
  assert.equal((await h.resolve('token',paid,'de',{transport:'vless'})).transport,'vless');
  const awg=await h.resolve('token',paid,'de',{allowPersistentHotProfile:false});
  assert.equal(awg.transport,undefined);
  assert.match(awg.config,/Address/);
  assert.deepEqual(h.calls,['vless','awg']);
});

test('a late VLESS profile cannot escape a superseded session', async () => {
  let complete, reached;
  const gate=new Promise(resolve=>{complete=resolve;});
  const started=new Promise(resolve=>{reached=resolve;});
  let current=true;
  const h=profileHarness({vless:async()=>{reached();await gate;return {device,config,expiresAt:response().expires_at,routeId:'route-1'};}});
  const pending=h.resolve('token',paid,'de',{transport:'vless',isCurrentSessionOperation:()=>current});
  await started;current=false;complete();
  await assert.rejects(pending,/superseded/i);
});

test('VLESS recovery reissues its own profile and fails over without WG key rotation', async () => {
  const {recoverVpnConnection}=load('src/vpn/connectionRecovery.ts',{
    './serverSelection':{chooseBestVpnLocation:rows=>rows[0]},'./locationId':{comparableVpnLocationId:id=>id},
    './vpnAutopilotAssessment':{assessVpnAutopilotIssue:()=>({cause:'key_or_profile'})},
  });
  let rotations=0,connects=0;const resolutions=[];
  const result=await recoverVpnConnection({activeProfile:vlessProfile(),activeLocationId:'de',availableLocations:[{id:'de'},{id:'fi'}],
    connectProfile:async profile=>{if(++connects<3)throw new Error('VPN connection failed');return {profile,status:{state:'connected'}};},
    isRetryableConnectError:()=>true,rotateProfile:async()=>{rotations++;throw new Error('WG rotation forbidden');},
    resolveProfile:async(location,options)=>{resolutions.push({location,...options});return {...vlessProfile(),locationId:location};},
    persistLocation:async location=>location,setCachedProfile:()=>{}});
  assert.equal(result.ok,true);assert.equal(rotations,0);assert.equal(resolutions.length,2);
  assert.equal(resolutions.every(row=>row.transport==='vless'),true);
});

function apiHarness({devices=[device],reply=response(),guard=()=>true,legacy=false,lostRegistration=false,onRegister=()=>{}}={}) {
  const calls=[];let pending=legacy,failRegistration=lostRegistration,confirmations=0;
  const identity=()=>({installationId:'physical',externalDeviceId:'physical',keyScope:'account-key',legacyOwnedDeviceId:legacy?'device':undefined,
    legacyRegistrationPending:pending,keyPair:{privateKey:'PRIVATE_FIXTURE',publicKey:'PUBLIC_FIXTURE',keyEpoch:1}});
  const dto=row=>({id:row.id,user_id:row.userId,status:row.status,external_device_id:row.externalDeviceId,protocol:row.protocol,
    provisioning_mode:row.provisioningMode,client_key_ownership:row.clientKeyOwnership,platform:row.platform,public_key:'PUBLIC_FIXTURE',psk_epoch:1});
  const prepared=raw('src/api/vpn.ts','preparedVlessTunnel',{
    Platform:{OS:'android'},requireVpnLocationId:value=>value,parseVlessProfileResponse,ApiRequestError,...sessionOperation,
    getOrCreateVpnAccountIdentity:async()=>identity(),withVpnAccountIdentity:async(_options,operation)=>operation(identity()),
    pendingVpnAccountKeyPair:async()=>undefined,confirmVpnAccountRegistration:async()=>{confirmations++;pending=false;},
    nativeVpnDeviceForClient:load('src/vpn/nativeDeviceSelection.ts',{'./locationId':{comparableVpnLocationId:id=>id}}).nativeVpnDeviceForClient,
    getOrCreateNativeDeviceRegistration:(_token,_id,operation)=>operation(),
    getAppInfo:async()=>({platform:'android',version:'1.0.83'}),
    getOrCreateDeviceIdentity:async()=>legacy?{publicKey:'P256_FIXTURE',keyType:'p256',sign:async()=> 'SIGNED_FIXTURE'}:null,
    deviceIdentitySignaturePayload:()=> 'FIXTURE_PAYLOAD',
    vpnAccountRegistrationIdempotencyKey:()=> 'fixture-registration', clientVersionHeaders:async()=>({'X-Vex-Platform':'android'}),
    jsonRequest:async(path,options)=>{
      calls.push({path,options});
      if(path.startsWith('/v1/vpn/profile')) throw Object.assign(new Error('AWG profile unavailable'), {status:500});
      if(path==='/v1/devices')return devices.map(dto);
      if(path==='/v1/devices/identity-challenge')return {id:'challenge',nonce:'nonce',purpose:'register'};
      if(path==='/v1/devices/register'){onRegister();if(failRegistration){failRegistration=false;throw new ApiRequestError('lost registration response',{code:'network_unavailable'});}return {device:dto(device)};}
      if(path==='/v1/vpn/vless-profile'){if(reply instanceof Error)throw reply;return reply;}
      throw new Error(`Forbidden API path ${path}`);
    },
  });
  return {calls,confirmations:()=>confirmations,pending:()=>pending,run:()=>prepared('token',{locationId:'de',userId:'owner',isCurrentSessionOperation:guard})};
}

test('VLESS works while the AWG profile endpoint is unavailable, without WG profile retrieval or key export', async () => {
  const h=apiHarness();
  assert.equal((await h.run()).device.id,'device');
  assert.deepEqual(h.calls.map(row=>row.path),['/v1/devices','/v1/vpn/vless-profile']);
  assert.equal(h.calls[1].options.headers['X-Vex-Platform'],'android');
  assert.deepEqual(h.calls[1].options.body,{device_id:'device',location_id:'de',transport_capability:'vless-xhttp-v1'});
  assert.equal(JSON.stringify(h.calls).includes('PRIVATE_FIXTURE'),false);
});

test('first VLESS use registers the existing physical native identity with a public key only', async () => {
  const h=apiHarness({devices:[]});await h.run();
  assert.deepEqual(h.calls.map(row=>row.path),['/v1/devices','/v1/devices/register','/v1/vpn/vless-profile']);
  const registration=h.calls[1].options.body;
  assert.equal(registration.device_id,'physical');assert.equal(registration.protocol,'amneziawg');
  assert.equal(registration.public_key,'PUBLIC_FIXTURE');
  assert.equal(JSON.stringify(h.calls).includes('PRIVATE_FIXTURE'),false);
});

test('API VLESS admission rejects cross-owner, inactive and mismatched bindings', async () => {
  for(const candidate of [{...device,userId:'other'},{...device,platform:'ios'},{...device,status:'suspended'}]) await assert.rejects(apiHarness({devices:[candidate]}).run());
  await assert.rejects(apiHarness({reply:{...response(),device_id:'other'}}).run(),/VLESS-профиль/);
});

function connectionFlowHarness({cancelOnRead=false}={}) {
  let cancelled=false,reads=0;const calls=[];
  const fallback=pure('connectionFallback');
  const hook=raw('src/vpn/useVpnConnectionFlow.ts','useVpnConnectionFlow',{
    useRef:current=>({current}),useEffect:()=>{},useCallback:callback=>callback,Platform:{OS:'android'},...sessionOperation,
    prepareClientNetworkDiagnostics:async()=>{},withTimeout:promise=>promise,vpnProfileAddressMatchesDevice:()=>true,
    androidVpnProfileWithinBinderBudget:()=>true,getVpnApplicationSelection:async()=>({mode:'selected',packageNames:['fixture.app']}),
    dynamicRouteRuntime:{prepare:()=>{throw new Error('AWG prepare forbidden');},attempts:()=>{throw new Error('AWG routes forbidden');},clearActive:()=>calls.push('clear-route')},
    connectionAttemptsForProfile:()=>{throw new Error('AWG fallback forbidden');},profileEndpoint:fallback.profileEndpoint,
    getVpnStatus:async()=>{
      if(++reads===1)return {state:'disconnected'};
      if(cancelOnRead)cancelled=true;
      return {state:'connected',transport:'vless',connectionId,verificationEpochMillis:Date.now(),verified:true};
    },
    connectVpn:async(_config,options)=>{calls.push(options);return {state:'verifying',transport:'vless',connectionId,verified:false};},
    connectAttemptTimeoutMs:25000,waitForVerifiedVpnConnection,scheduleVpnVerificationTimeout,withLastSuccessfulEndpoint:profile=>profile,isVpnTransportFallbackError:fallback.isVpnTransportFallbackError,
  });
  return {calls,flow:hook({isCurrentSessionOperation:()=>!cancelled,antiLeakEnabled:true,session:{accessToken:'token',user:{id:'owner'}}})};
}

test('the actual connection flow bypasses AWG routes and verifies the VLESS attempt',async()=>{
  const h=connectionFlowHarness();
  const connected=await h.flow.connectProfileWithEndpointFallback(vlessProfile());
  assert.equal(connected.status.transport,'vless');assert.equal(connected.status.verified,true);
  assert.equal(h.calls[0].transport,'vless');assert.equal(h.calls[1],'clear-route');
});

test('VLESS proof returned after cancellation cannot publish a connection result',async()=>{
  const h=connectionFlowHarness({cancelOnRead:true});
  await assert.rejects(h.flow.connectProfileWithEndpointFallback(vlessProfile()),/superseded/);
  assert.equal(h.calls.length,1);
});

test('an explicit AWG verification cannot accept a VLESS status even with a fabricated handshake',async()=>{
  const status={state:'connected',transport:'vless',verified:true,connectionId,verificationEpochMillis:500,latestHandshakeEpochMillis:500};
  await assert.rejects(waitForVerifiedVpnConnection(status,async()=>status,{transport:'amneziawg',minimumHandshakeEpochMillis:400,now:()=>1000,attempts:1}),/timed out/);
});

test('VLESS credentials are never written into durable hot-profile storage',async()=>{
  let storageReads=0,writes=0;
  const cache=load('src/vpn/hotProfileCache.ts',{
    'react-native':{Platform:{OS:'android'}},'@/native/secureStore':{
      getItemAsync:async()=>{storageReads++;return null;},setItemAsync:async()=>{writes++;},
    },'./routingPolicy':{},'./hotProfileCacheCore':load('src/vpn/hotProfileCacheCore.ts',{'./locationId':{comparableVpnLocationId:id=>id,requireVpnLocationId:id=>id}}),
  });
  assert.equal(await cache.saveHotVpnProfile('owner','de',vlessProfile()),null);
  assert.equal(storageReads,0);assert.equal(writes,0);
});

test('a pending profile operation loses authority when the preferred protocol changes',async()=>{
  let finish,reached,cursor=0;const slots=[],cache=[];
  const gate=new Promise(resolve=>{finish=resolve;});const started=new Promise(resolve=>{reached=resolve;});
  const hook=raw('src/vpn/useVpnProfileState.ts','useVpnProfileState',{
    useRef:initial=>{const index=cursor++;return slots[index]??(slots[index]={current:initial});},
    useState:initial=>{const index=cursor++;slots[index]??=initial;return [slots[index],value=>{slots[index]=typeof value==='function'?value(slots[index]):value;}];},
    useMemo:fn=>fn(),useCallback:fn=>fn,useEffect:()=>{},
    useQueryClient:()=>({getQueryData:()=>null,setQueryData:(_key,value)=>cache.push(value)}),
    resolveVpnProfile:async(_token,_entitlement,_location,options)=>{reached();await gate;assert.equal(options.isCurrentSessionOperation(),false);return vlessProfile();},
    connectableLocalProfile:()=>null,...transport,...sessionOperation,
  });
  const render=protocol=>{cursor=0;return hook({transport:protocol,routingMode:'full_tunnel',accessToken:'token',userId:'owner',
    selectedLocationId:'de',isCurrentSessionOperation:()=>true,knownEntitlement:paid,requestVpnPermission:async()=>true});};
  const old=render('vless');
  const pending=old.resolveConnectableVpnProfile('de',{forceRefresh:true});
  await started;render('amneziawg');finish();
  await assert.rejects(pending,/superseded/);assert.equal(cache.length,0);
});


test('an unavailable VLESS endpoint reports a clean typed error without an AWG request',async()=>{
  for(const status of [404,503]){
    const h=apiHarness({reply:new ApiRequestError('internal detail',{status,code:'vless_unavailable'})});
    await assert.rejects(h.run(),error=>error.status===status&&error.message.includes('VLESS пока недоступен'));
    assert.deepEqual(h.calls.map(row=>row.path),['/v1/devices','/v1/vpn/vless-profile']);
  }
});

for (const supersede of ['none','session','connection']) {
  test(`resuming a live native VLESS tunnel preserves the active protocol and rejects stale ${supersede} ownership`,async()=>{
    const file='src/vpn/useVpnConnection.ts';const source=fs.readFileSync(path.join(root,file),'utf8');
    const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let callback;
    const visit=node=>{
      if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&node.arguments[0].getText(ast).includes('const ownsNativeConnection ='))callback=node.arguments[0].getText(ast);
      ts.forEachChild(node,visit);
    };visit(ast);assert.ok(callback);
    let finish,current=true;const gate=new Promise(resolve=>{finish=resolve;});const published=[],cached=[];
    const native={transport:'vless',state:'connected',connectionId};
    const context={session:{accessToken:'token',user:{id:'owner'}},hasVpnAccess:true,selectedLocationId:'de',
      vpnStatusCore:native,vpnStatusRef:{current:native},activeProfile:{transport:'amneziawg'},
      vpnOperationInFlightRef:{current:false},selectedLocationIdRef:{current:'de'},knownEntitlement:paid,
      isCurrentSessionOperation:()=>current,
      resolveVpnProfile:async(_token,_entitlement,_location,options)=>{
        assert.equal(options.transport,'vless');assert.equal(options.isCurrentSessionOperation(),true);
        await gate;return vlessProfile();
      },cacheProfile:(_location,profile)=>cached.push(profile),setActiveProfile:profile=>published.push(profile)};
    const code=ts.transpileModule(`return (${callback});`,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
    const cleanup=new Function(...Object.keys(context),code)(...Object.values(context))();
    if(supersede==='session')current=false;
    if(supersede==='connection')context.vpnStatusRef.current={...native,connectionId:otherConnectionId};
    finish();await new Promise(setImmediate);
    assert.equal(published.length,supersede==='none'?1:0);assert.equal(cached.length,published.length);
    if(published[0])assert.equal(published[0].transport,'vless');
    cleanup();
  });
}

for (const profileTransport of [undefined,'amneziawg','vless']) {
  test(`recovery pins active ${profileTransport ?? 'legacy AWG'} across a different saved preference`,async()=>{
    const {recoverVpnConnection}=load('src/vpn/connectionRecovery.ts',{
      './serverSelection':{chooseBestVpnLocation:rows=>rows[0]},'./locationId':{comparableVpnLocationId:id=>id},
      './vpnAutopilotAssessment':{assessVpnAutopilotIssue:()=>({cause:'network'})},
    });
    const expected=profileTransport??'amneziawg';let connects=0;const requests=[];
    const active={...vlessProfile(),transport:profileTransport,routingMode:expected==='vless'?'full_tunnel':'all_except_ru'};
    const result=await recoverVpnConnection({activeProfile:active,activeLocationId:'de',availableLocations:[{id:'de'},{id:'fi'}],
      connectProfile:async profile=>{if(++connects<3)throw new Error('path failed');return {profile,status:{state:'connected'}};},
      isRetryableConnectError:()=>true,persistLocation:async id=>id,setCachedProfile:()=>{},
      resolveProfile:async(locationId,options)=>{requests.push(options);return {...active,locationId,transport:options.transport??(expected==='vless'?'amneziawg':'vless')};}});
    assert.equal(result.ok,true);assert.equal(requests.length,2);
    for(const request of requests){assert.equal(request.transport,expected);assert.equal(request.routingMode,active.routingMode);}
  });
}

test('failed VLESS switching restores the previous legacy AWG protocol and routing',async()=>{
  const {switchVpnLocation}=load('src/vpn/serverSwitch.ts',{'./sessionOperation':sessionOperation});
  const previous={...vlessProfile(),transport:undefined,locationId:'de',routingMode:'all_except_ru'};const requests=[];
  const result=await switchVpnLocation({previousLocationId:'de',targetLocationId:'fi',previousProfile:previous,
    previousStatus:{state:'connected'},isRetryableConnectError:()=>false,persistLocation:async id=>id,setCachedProfile:()=>{},
    resolveProfile:async(locationId,options)=>{
      requests.push({locationId,...options});return {...previous,locationId,transport:options.transport??'vless',routingMode:options.routingMode??'full_tunnel'};
    },connectProfile:async profile=>{if(profile.locationId==='fi')throw new Error('VLESS path failed');return {profile,status:{state:'connected'}};}});
  assert.equal(result.rollback,'reconnected');assert.equal(result.profile.transport,'amneziawg');assert.equal(result.profile.routingMode,'all_except_ru');
  assert.equal(requests[1].transport,'amneziawg');assert.equal(requests[1].routingMode,'all_except_ru');
});

function connectionCallbacks() {
  const file='src/vpn/useVpnConnection.ts',source=fs.readFileSync(path.join(root,file),'utf8');
  const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true),callbacks={};
  const visit=node=>{
    if(ts.isVariableDeclaration(node)&&['captureStatusReadOwner','refreshVpnStatus'].includes(node.name.getText(ast)))callbacks[node.name.getText(ast)]=node.initializer.arguments[0].getText(ast);
    if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&node.arguments[0].getText(ast).includes("refreshVpnStatus('native_status_poll_failed'"))callbacks.poll=node.arguments[0].getText(ast);
    if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&node.arguments[0].getText(ast).includes("refreshVpnStatus('native_status_startup_failed'"))callbacks.startup=node.arguments[0].getText(ast);
    if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&node.arguments[0].getText(ast).includes("refreshVpnStatus('native_status_on_active_failed'"))callbacks.foreground=node.arguments[0].getText(ast);
    ts.forEachChild(node,visit);
  };visit(ast);
  const profileAst=ts.createSourceFile('useVpnProfileState.ts',fs.readFileSync(path.join(root,'src/vpn/useVpnProfileState.ts'),'utf8'),ts.ScriptTarget.Latest,true);
  const visitProfile=node=>{
    if(ts.isVariableDeclaration(node)&&node.name.getText(profileAst)==='setVpnProfile')callbacks.setProfile=node.initializer.arguments[0].getText(profileAst);
    ts.forEachChild(node,visitProfile);
  };visitProfile(profileAst);return callbacks;
}
const statusCallbacks=connectionCallbacks();
function bindCallback(callback,context){
  // The isolated callback delegates lease lifecycle to its hook boundary.
  const operation = context.vpnOperationInFlightRef;
  context = {...context,
    acquireVpnOperation: context.acquireVpnOperation ?? (() => { operation.current = true; return () => { operation.current = false; }; }),
    releaseVpnOperation: () => { operation.current = false; },
  };

  const code=ts.transpileModule(`return (${callback});`,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
  return new Function(...Object.keys(context),code)(...Object.values(context));
}
function statusReadHarness({poll=false,initial={state:'connected',transport:'vless',connectionId,verified:true,verificationEpochMillis:100}}={}){
  let finish,tick,current=true,reads=0,diagnostics=0,recorded=0;const published=[];
  const gate=new Promise(resolve=>{finish=resolve;});
  const context={activeProfileRevisionRef:{current:0},vpnMountedRef:{current:true},vpnOperationRevisionRef:{current:0},preferencesRevisionRef:{current:0},vpnConnectGenerationRef:{current:1},selectedLocationIdRef:{current:'de'},vpnStatusRef:{current:initial},
    vpnOperationInFlightRef:{current:false},isCurrentSessionOperation:()=>current,
    getVpnStatus:async()=>{reads++;return gate;},setVpnStatus:update=>{
      const next=typeof update==='function'?update(context.vpnStatusRef.current):update;
      if(next!==context.vpnStatusRef.current)published.push(next);
      context.vpnStatusRef.current=next;
    },areVpnStatusesEqual:(a,b)=>a===b,errorMessage:error=>String(error),submitClientDiagnosticsEvent:async()=>{diagnostics++;}};
  context.captureStatusReadOwner=bindCallback(statusCallbacks.captureStatusReadOwner,context);
  const refresh=bindCallback(statusCallbacks.refreshVpnStatus,context);
  let cleanup;
  if(poll){
    cleanup=bindCallback(statusCallbacks.poll,{...context,isAppActive:true,session:{user:{id:'owner'}},supportsNativeStatusPolling:()=>true,
      Platform:{OS:'android'},vpnStatusCore:initial,isConnected:true,connectedNativeStatusPollMs:5000,nativeStatusPollMs:2500,
      statusPollingRef:{current:{refreshVpnStatus:refresh,recordNativeStatus:()=>{recorded++;return false;}}},
      setInterval:fn=>{tick=fn;return 1;},clearInterval:()=>{}})();
  }
  return {context,published,finish,refresh,poll:()=>tick(),cleanup:()=>cleanup?.(),invalidate:()=>{current=false;},
    reads:()=>reads,diagnostics:()=>diagnostics,recorded:()=>recorded};
}

for(const poll of [false,true])for(const mutation of ['logout-login','connection','generation','location','profile','same-account-token-refresh']){
  test(`${poll?'polling callback':'status refresh'} gates ${mutation} without confusing profile hydration with a new connection`,async()=>{
    const h=statusReadHarness({poll});let pending;
    if(poll)h.poll();else pending=h.refresh('fixture');
    await Promise.resolve();assert.equal(h.reads(),1);
    if(mutation==='logout-login'){h.invalidate();h.context.vpnStatusRef.current={state:'disconnected',connectionId:otherConnectionId};}
    if(mutation==='connection')h.context.vpnStatusRef.current={...h.context.vpnStatusRef.current,connectionId:otherConnectionId};
    if(mutation==='generation')h.context.vpnConnectGenerationRef.current++;
    if(mutation==='location')h.context.selectedLocationIdRef.current='fi';
    if(mutation==='profile')h.context.activeProfileRevisionRef.current++;
    // Token refresh keeps the login guard, generation, location and native ID.
    if(mutation==='same-account-token-refresh')h.context.refreshedAccessToken='new-token';
    h.finish({state:'connected',transport:'vless',connectionId,verified:true,verificationEpochMillis:200});
    if(pending)await pending;await new Promise(setImmediate);
    const benign=mutation==='same-account-token-refresh'||mutation==='profile';
    assert.equal(h.published.length,benign?1:0);
    assert.equal(h.recorded(),poll&&benign?1:0);
    assert.equal(h.diagnostics(),0);h.cleanup();
  });
}

for(const phase of ['startup','foreground']){
  test(`actual ${phase} effect converges after hot-profile hydration while its only native read is pending`,async()=>{
    const h=statusReadHarness({initial:{state:'disconnected',rxBytes:0,txBytes:0}});
    let onAppState,hydrated=null;
    const cleanup=bindCallback(statusCallbacks[phase],{
      ...h.context,refreshVpnStatus:h.refresh,session:{user:{id:'fixture-owner'}},
      AppState:{addEventListener:(_event,callback)=>{onAppState=callback;return {remove:()=>{}};}},
      setIsAppActive:()=>{},refreshLocations:async()=>{},refreshManagedProfile:async()=>{},
    })();
    if(phase==='foreground')onAppState('active');
    assert.equal(h.reads(),1);
    // Exercise the real authoritative setter, without a native event or a
    // repeated effect/read. Profile hydration does not change the live tunnel.
    const setProfile=bindCallback(statusCallbacks.setProfile,{
      ...h.context,userId:'fixture-owner',vpnProfileOwnerRef:{current:null},
      setVpnProfileState:update=>{hydrated=update(hydrated);},
    });
    setProfile({locationId:'de',profileVersion:7,device:{id:'fixture-device'}});
    assert.equal(h.context.activeProfileRevisionRef.current,1);
    assert.equal(hydrated.profileVersion,7);
    const fresh={state:'connected',transport:'amneziawg',verified:true,rxBytes:0,txBytes:0,
      latestHandshakeEpochMillis:Date.now(),leakProtection:'armed'};
    h.finish(fresh);await new Promise(setImmediate);
    assert.deepEqual(h.published,[fresh]);
    assert.equal(h.context.vpnStatusRef.current.state,'connected');
    assert.equal(h.reads(),1,'no native event replay, new timer or retry is needed');
    assert.equal(h.diagnostics(),0);cleanup?.();
  });
}


test('an upgraded legacy Android registers its P256 binding before requesting VLESS without an AWG profile',async()=>{
  const h=apiHarness({legacy:true});await h.run();
  assert.deepEqual(h.calls.map(row=>row.path),['/v1/devices','/v1/devices/identity-challenge','/v1/devices/register','/v1/vpn/vless-profile']);
  const registration=h.calls.find(row=>row.path==='/v1/devices/register').options.body;
  assert.equal(registration.identity_public_key,'P256_FIXTURE');assert.equal(registration.identity_signature,'SIGNED_FIXTURE');
  assert.equal(h.confirmations(),1);assert.equal(h.pending(),false);
  assert.equal(JSON.stringify(h.calls).includes('PRIVATE_FIXTURE'),false);
});

test('a lost legacy registration response retains migration intent and safely retries the same identity before VLESS',async()=>{
  const h=apiHarness({legacy:true,lostRegistration:true});
  await assert.rejects(h.run(),/lost registration response/);
  assert.equal(h.pending(),true);assert.equal(h.confirmations(),0);
  assert.equal(h.calls.some(row=>row.path==='/v1/vpn/vless-profile'),false);
  await h.run();assert.equal(h.pending(),false);assert.equal(h.confirmations(),1);
  const registrations=h.calls.filter(row=>row.path==='/v1/devices/register');assert.equal(registrations.length,2);
  assert.deepEqual(registrations[0].options.body,registrations[1].options.body);
  assert.equal(h.calls.filter(row=>row.path==='/v1/vpn/vless-profile').length,1);
});

test('legacy VLESS registration cannot confirm or issue credentials after the account owner changes',async()=>{
  let current=true;
  const h=apiHarness({legacy:true,guard:()=>current,onRegister:()=>{current=false;}});
  await assert.rejects(h.run(),/superseded/);
  assert.equal(h.pending(),true);assert.equal(h.confirmations(),0);
  assert.equal(h.calls.some(row=>row.path==='/v1/vpn/vless-profile'),false);
  const foreign=apiHarness({legacy:true,devices:[{...device,userId:'another-account'}]});
  await assert.rejects(foreign.run(),/другому аккаунту/);
  assert.deepEqual(foreign.calls.map(row=>row.path),['/v1/devices']);
});

test('a bootstrap native status read survives harmless saved-location hydration',async()=>{
  const h=statusReadHarness();h.context.vpnStatusRef.current={state:'disconnected'};h.context.selectedLocationIdRef.current='';
  const pending=h.refresh('fixture');h.context.selectedLocationIdRef.current='de';
  h.finish({state:'connected',transport:'vless',connectionId,verified:true,verificationEpochMillis:200});
  await pending;assert.equal(h.published.length,1);
});


function connectionDeclaration(name) {
  const file='src/vpn/useVpnConnection.ts',source=fs.readFileSync(path.join(root,file),'utf8');
  const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let declaration;
  const visit=node=>{
    if(ts.isVariableDeclaration(node)&&node.name.getText(ast)===name)declaration=node.initializer.getText(ast);
    if(ts.isFunctionDeclaration(node)&&node.name?.getText(ast)===name)declaration=node.getText(ast);
    ts.forEachChild(node,visit);
  };visit(ast);assert.ok(declaration);return declaration;
}
const autopilotExpression=connectionDeclaration('isAutopilotActive');
const autopilotPolicy=new Function('vpnStatusCore','isConnected',`return (${autopilotExpression});`);

for(const leakProtection of ['off','blocking'])for(const connectionWanted of [true,false]){
  test(`VLESS wanted=${connectionWanted} drives recovery with leak protection ${leakProtection}`,async()=>{
    for(const state of ['connected','degraded','verifying','error','disconnected','disconnecting']){
      const h=nativeHarness({status:{state,transport:'vless',connectionId,connectionWanted,leakProtection,rxBytes:0,txBytes:0,verified:false}});
      const normalized=await h.native.getVpnStatus({fresh:true});
      assert.equal(normalized.connectionWanted,connectionWanted);
      assert.equal(autopilotPolicy(normalized,state==='connected'),connectionWanted,state);
    }
  });
}

test('an absent or malformed VLESS wanted flag cannot enable recovery after an explicit stop',async()=>{
  for(const connectionWanted of [undefined,'true','false',1]){
    const h=nativeHarness({status:{state:'error',transport:'vless',connectionWanted,leakProtection:'blocking',rxBytes:0,txBytes:0}});
    const normalized=await h.native.getVpnStatus({fresh:true});
    assert.equal(normalized.connectionWanted,undefined);assert.equal(autopilotPolicy(normalized,false),false);
  }
});

test('AWG binaries without the optional intent flag retain their legacy recovery behavior',()=>{
  for(const transport of [undefined,'amneziawg'])for(const state of ['connected','degraded','verifying','error','disconnected']){
    assert.equal(autopilotPolicy({transport,state},state==='connected'),state==='connected'||state==='degraded');
  }
});

test('persisted AWG intent recovers a protected native failure and an explicit stop disables recovery',async()=>{
  for(const transport of [undefined,'amneziawg'])for(const connectionWanted of [true,false]){
    for(const state of ['connected','degraded','error','disconnected']){
      const h=nativeHarness({status:{state,transport,connectionWanted,leakProtection:'blocking',rxBytes:0,txBytes:0}});
      const normalized=await h.native.getVpnStatus({fresh:true});
      assert.equal(normalized.connectionWanted,connectionWanted);
      assert.equal(autopilotPolicy(normalized,state==='connected'),connectionWanted,`${state}/${connectionWanted}`);
    }
  }
  assert.equal(autopilotPolicy({state:'error',connectionWanted:true,leakProtection:'off'},false),false);
  assert.equal(autopilotPolicy({state:'error',leakProtection:'blocking'},false),false);
});

test('a wanted-only transition updates both status memoization layers',()=>{
  const coreCode=ts.transpileModule(connectionDeclaration('areVpnStatusCoresEqual'),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
  const coreEqual=new Function(coreCode+';return areVpnStatusCoresEqual;')();
  const source=fs.readFileSync(path.join(root,'src/screens/home-screen-helpers.ts'),'utf8');
  const ast=ts.createSourceFile('helpers.ts',source,ts.ScriptTarget.Latest,true);let helper;
  ast.forEachChild(node=>{if(ts.isFunctionDeclaration(node)&&node.name?.getText(ast)==='areVpnStatusesEqual')helper=node.getText(ast);});
  const helperCode=ts.transpileModule(helper.replace(/^export /,''),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
  const statusEqual=new Function(helperCode+';return areVpnStatusesEqual;')();
  const current={state:'error',transport:'vless',connectionId,connectionWanted:true,rxBytes:0,txBytes:0,leakProtection:'off'};
  for(const equal of [coreEqual,statusEqual]){
    assert.equal(equal(current,{...current}),true);
    assert.equal(equal(current,{...current,connectionWanted:false}),false);
  }
});

test('an in-flight status read cannot re-enable connection intent after an explicit stop',async()=>{
  const h=statusReadHarness();h.context.vpnStatusRef.current={...h.context.vpnStatusRef.current,connectionWanted:true};
  const pending=h.refresh('fixture');h.context.vpnStatusRef.current={...h.context.vpnStatusRef.current,connectionWanted:false};
  h.finish({...h.context.vpnStatusRef.current,connectionWanted:true});
  assert.equal(await pending,null);assert.equal(h.published.length,0);
});

function permissionChainHarness({cached=false,nativeFailures=0,missingInitial=false}={}){
  let permissions=0,attempts=0;const resolutions=[],published=[],failures=[];
  const profileFor=locationId=>({...vlessProfile(),locationId,source:cached?'local':'api'});
  const fallback=pure('connectionFallback');
  const connectFlow=load('src/vpn/connectFlow.ts',{'./profileConsistency':pure('profileConsistency'),'./connectionFallback':fallback});
  const profileFallback=load('src/vpn/profileResolutionFallback.ts',{'@/api/error':{ApiRequestError},'./serverSelection':{isSelectableLocation:()=>true}});
  const react={useRef:current=>({current}),useState:initial=>[initial,()=>{}],useMemo:fn=>fn(),useCallback:fn=>fn,useEffect:()=>{}};
  const profileHook=raw('src/vpn/useVpnProfileState.ts','useVpnProfileState',{
    ...react,...transport,...sessionOperation,connectableLocalProfile:connectFlow.connectableLocalProfile,
    useQueryClient:()=>({getQueryData:key=>cached?profileFor(key[2]):null,setQueryData:()=>{}}),saveHotVpnProfile:async()=>null,
    resolveVpnProfile:async(_token,_entitlement,location)=>{
      if(missingInitial&&location==='de')throw new ApiRequestError('location unavailable',{status:404});
      return {...profileFor(location),source:'api'};
    },
  });
  const profileState=profileHook({transport:'vless',routingMode:'full_tunnel',accessToken:'token',userId:'owner',selectedLocationId:'de',
    isCurrentSessionOperation:()=>true,knownEntitlement:paid,hasVpnAccess:true,requestVpnPermission:async()=>{permissions++;return true;}});
  const flowHook=raw('src/vpn/useVpnConnectionFlow.ts','useVpnConnectionFlow',{
    ...react,...sessionOperation,...profileFallback,...connectFlow,
    Platform:{OS:'android'},prepareClientNetworkDiagnostics:async()=>{},withTimeout:promise=>promise,
    vpnProfileAddressMatchesDevice:()=>true,androidVpnProfileWithinBinderBudget:()=>true,
    getVpnApplicationSelection:async()=>({mode:'all',packageNames:[]}),
    dynamicRouteRuntime:{prepare:()=>{throw new Error('AWG prepare forbidden');},attempts:()=>{throw new Error('AWG fallback forbidden');},clearActive:()=>{}},
    profileEndpoint:fallback.profileEndpoint,isVpnTransportFallbackError:fallback.isVpnTransportFallbackError,
    getVpnStatus:async()=>({state:'disconnected'}),connectVpn:async()=>{
      if(++attempts<=nativeFailures)throw new Error('VPN connection failed');
      return {state:'connected',transport:'vless',connectionWanted:true,connectionId,verified:true,verificationEpochMillis:Date.now()};
    },connectAttemptTimeoutMs:25000,waitForVerifiedVpnConnection,scheduleVpnVerificationTimeout,withLastSuccessfulEndpoint:profile=>profile,
    connectFreshSameLocationProfile:pure('sameLocationProfileRecovery').connectFreshSameLocationProfile,
    saveHotVpnProfile:async()=>null,uploadClientDiagnostics:async()=>{},setSelectedVpnLocation:async id=>id,errorMessage:error=>error.message,
  });
  const flow=flowHook({isCurrentSessionOperation:()=>true,antiLeakEnabled:true,selectedLocationId:'de',serverSelectionMode:'manual',
    availableLocations:[{id:'de'},{id:'fi'}],cacheProfile:()=>{},
    resolveConnectableVpnProfile:(location,options)=>{resolutions.push(options);return profileState.resolveConnectableVpnProfile(location,options);},
    vpnStatus:{state:'disconnected'},clientLatencyMs:null,reportVpnConnectEvent:()=>{},setSelectedLocationId:()=>{},
    setActiveProfile:profile=>published.push(profile),setVpnStatus:()=>{},session:{accessToken:'token',user:{id:'owner'}}});
  const file='src/vpn/useVpnConnection.ts',source=fs.readFileSync(path.join(root,file),'utf8');
  const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let effect;
  const visit=node=>{
    if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&node.arguments[0].getText(ast).includes('getAndroidAutoConnectEnabled()'))effect=node.arguments[0].getText(ast);
    ts.forEachChild(node,visit);
  };visit(ast);assert.ok(effect);
  const startAuto=()=>bindCallback(effect,{Platform:{OS:'android'},autoConnectAttemptedRef:{current:false},isConnected:false,isVpnBusy:false,
    vpnOperationInFlightRef:{current:false},session:{accessToken:'token',user:{id:'owner'}},entitlementState:paid,hasPaidEntitlement:()=>true,
    vpnConnectGenerationRef:{current:0},getAndroidAutoConnectEnabled:async()=>true,setIsVpnBusy:()=>{},setVpnError:()=>{},setVpnStatus:()=>{},
    nextVpnStatusWithState:()=>{},connectCurrentVpn:flow.connectCurrentVpn,isCurrentSessionOperation:()=>true,handleVpnFailure:error=>failures.push(error)})();
  return {flow,startAuto,published,resolutions,failures,permissions:()=>permissions,attempts:()=>attempts};
}

for(const automatic of [true,false])for(const nativeFailures of [0,1,3]){
  test(`${automatic?'automatic':'manual'} VLESS real resolver chain requests permission only for the initial manual connect (${nativeFailures} failed attempts)`,async()=>{
    const h=permissionChainHarness({cached:nativeFailures===1,nativeFailures});let cleanup;
    if(automatic){cleanup=h.startAuto();for(let i=0;i<10&&!h.published.length&&!h.failures.length;i++)await new Promise(setImmediate);}
    else await h.flow.connectCurrentVpn();
    assert.deepEqual(h.failures,[]);assert.equal(h.published.length,1);assert.equal(h.permissions(),automatic?0:1);
    assert.equal(h.attempts(),nativeFailures+1);
    assert.equal(h.resolutions.filter(options=>options.requestPermission!==false).length,automatic?0:1);
    if(nativeFailures===3)assert.equal(h.published[0].locationId,'fi');
    cleanup?.();
  });
}

test('automatic initial-location profile fallback also cannot obtain a VPN permission grant',async()=>{
  const h=permissionChainHarness({missingInitial:true});const cleanup=h.startAuto();
  for(let i=0;i<10&&!h.published.length&&!h.failures.length;i++)await new Promise(setImmediate);
  assert.deepEqual(h.failures,[]);assert.equal(h.published[0].locationId,'fi');assert.equal(h.permissions(),0);
  assert.equal(h.resolutions.length,2);assert.equal(h.resolutions.every(options=>options.requestPermission===false),true);cleanup();
});
