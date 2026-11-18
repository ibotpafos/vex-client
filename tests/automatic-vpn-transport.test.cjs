const assert = require('node:assert/strict');
const test = require('node:test');
const {loadWithBindings, loadModule, accountFixture} = require('./vpn-module-loader.cjs');
const errors = loadModule('src/api/error.ts');
const {ApiRequestError} = errors;
const failure = (code, status) => new ApiRequestError('fixture unavailable', {code, status});

test('new Android preferences default to auto and preserve both existing explicit choices', async () => {
  for (const stored of [null, 'auto', 'amneziawg', 'vless']) {
    let saved;
    const prefs = loadWithBindings('src/settings/vpnPreferences.ts', null, {
      Platform:{OS:'android'}, supportsNativeRoutingPolicy:()=>false, supportsNativeVless:()=>true,
      SecureStore:{getItemAsync:async()=>stored,setItemAsync:async(_key,value)=>{saved=value;}},
    });
    assert.equal(await prefs.getVpnTransport(), stored ?? 'auto');
    assert.equal(await prefs.setVpnTransport('auto'), 'auto'); assert.equal(saved,'auto');
  }
});

function harness({preference='auto', profileError, nativeError, stopFails=false, live=false, supported=true, invalidAddress=false, invalidKey=false, nativeLive=false, initialStatus, settledDisconnect, disconnectWait, observation, now, nativeAdmissionWait, ...settings}={}) {
  const account = accountFixture({owner:'owner',deviceId:'device'});
  const events=[], publications=[], cache=[], disconnectOptions=[], locations=[], refs=[];
  let cursor=0;
  const ownerGuard=()=>current;
  let nativeCalls=0;
  let current=true, status=initialStatus??{state:live||nativeLive?'connected':'disconnected',transport:'vless',verified:live||nativeLive};
  const profile = protocol => ({locationId:'de',transport:protocol,source:'api',routingMode:'full_tunnel',device:{...account.device,...(invalidAddress?{assignedIpv4:'10.0.0.99'}:{})},
    config:protocol==='vless'?'{}':`[Interface]\nPrivateKey = ${invalidKey?'invalid':account.keyPair.privateKey}\nAddress = 10.0.0.2/32\nHeaderProtectionKey = fixture\n[Peer]\nEndpoint = fixture.invalid:443\n`});
  const {useVpnConnectionFlow:runFlow} = loadWithBindings('src/vpn/useVpnConnectionFlow.ts',null,{
    useRef:value=>{const i=cursor++;return refs[i]??(refs[i]={current:value});},useEffect:()=>{},useCallback:f=>f, Platform:{OS:'android'},
    readVpnNetworkObservation:async()=>observation?.()??{networkClass:'unknown',generation:''},
    ...account.api, supportsNativeVless:()=>supported,
    ...(nativeAdmissionWait?{withCurrentVpnProfileKey:(token,profile,dispatch,options)=>account.api.withCurrentVpnProfileKey(token,profile,async()=>{
      await nativeAdmissionWait(profile);return dispatch();
    },options)}:{}),
    prepareClientNetworkDiagnostics:async()=>{},getVpnApplicationSelection:async()=>({mode:'all',packageNames:[]}),
    dynamicRouteRuntime:{prepare:async()=>{},attempts:p=>[{profile:p}],clearActive:()=>{}},
    androidVpnProfileWithinBinderBudget:()=>true,
    connectVpn:async(_config,options)=>{
      events.push(['native',options.transport]);
      const error=nativeError?.(options.transport);if(error)throw error;
      status={state:'connected',transport:options.transport,verified:true,connectionId:(++nativeCalls).toString(16).padStart(8,'0')+'-1234-1234-1234-123456789abc',
        verificationEpochMillis:now?.()??Date.now(),latestHandshakeEpochMillis:now?.()??Date.now(),dataPlaneGeneration:'fixture',
        dataPlaneVerified:true,dataPlaneVerificationEpochMillis:now?.()??Date.now()};
      return status;
    },
    getVpnStatus:async()=>status,
    scheduleVpnVerificationTimeout:(ms, callback)=>{const timer=setTimeout(callback,ms);return ()=>clearTimeout(timer);},
    disconnectVpn:async options=>{disconnectOptions.push(options);events.push(['stop']);if(stopFails)throw new Error('stop failed');await disconnectWait?.();status=settledDisconnect??{state:'disconnected'};return status;},
    saveHotVpnProfile:async()=>{}, uploadClientDiagnostics:async()=>{},
    setSelectedVpnLocation:async id=>id,
  },now?{Date:class extends Date {static now(){return now();}}}:{});
  const input={transportPreference:preference,supportsVless:true,isCurrentSessionOperation:ownerGuard,antiLeakEnabled:true,
    selectedLocationId:'de',serverSelectionMode:'manual',availableLocations:[{id:'de',availability:'available',status:'active',healthyNodes:1,capabilities:['vless-xhttp-v1']},{id:'fi',availability:'available',status:'active',healthyNodes:1,capabilities:['vless-xhttp-v1']}],routingMode:'full_tunnel',
    cacheProfile:(_id,p)=>cache.push(p),
    resolveConnectableVpnProfile:async(_location,options)=>{
      const protocol=options.transport??(input.transportPreference==='vless'?'vless':'amneziawg'); events.push(['profile',protocol]);locations.push(_location);
      if(options.isCurrentOperation?.()===false) throw new (loadModule('src/vpn/sessionOperation.ts').SessionOperationSupersededError)();
      const error=await profileError?.(protocol);if(error)throw error;return {...profile(protocol),locationId:settings.actualLocation??_location};
    },
    vpnStatus:nativeLive?{state:'disconnected'}:status,clientLatencyMs:null,reportVpnConnectEvent:()=>{},setSelectedLocationId:()=>{},
    setActiveProfile:p=>publications.push(p),setVpnStatus:s=>{assert.equal(s.verified,true);events.push(['verified',s.transport]);status=s;},session:{accessToken:'fixture',user:{id:'owner'}},...settings};
  const h={events,publications,cache,disconnectOptions,locations,drop:()=>{status={state:'disconnected'};},invalidate:()=>{current=false;},
    render:patch=>{Object.assign(input,patch);cursor=0;h.flow=runFlow(input);}};
  h.render({});return h;
}

test('auto verifies the first protocol once without probing the alternate',async()=>{
  const h=harness();await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['verified','amneziawg']]);
  assert.equal(h.publications.length,1);
});

test('typed protocol unavailability permits one serial alternate and publishes only verified success',async()=>{
  const h=harness({profileError:protocol=>protocol==='amneziawg'?failure('protocol_not_supported',501):null});
  await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','amneziawg'],['profile','vless'],['native','vless'],['verified','vless']]);
  assert.deepEqual(h.publications.map(p=>p.transport),['vless']);
});

for (const error of [failure('unauthorized',401),failure('forbidden',403),failure('quota',402),
  failure('protocol_not_supported',401),failure('vless_unavailable',503),failure('awg_unavailable',503),
  failure('protocol_unavailable',503),failure('protocol_not_supported',503),failure(undefined,503),failure(undefined,404),failure('network_unavailable'),failure('request_timeout'),
  failure('request_cancelled'),failure('recovery_status_ambiguous'),failure('VPN_PROFILE_KEY_CHANGED'),
  new TypeError('connection reset'),new Error('unrecognized profile failure')]) {
  test(`auto never reissues ambiguous or denied preparation: ${error.code??error.message}`,async()=>{
    const h=harness({profileError:()=>error});
    await assert.rejects(h.flow.connectCurrentVpn(),actual=>actual===error);
    assert.deepEqual(h.events,[['profile','amneziawg']]);assert.equal(h.publications.length,0);
  });
}

test('retryable native failure must stop before a serial alternate native dispatch',async()=>{
  const h=harness({nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop'],['profile','vless'],['native','vless'],['verified','vless']]);
  assert.deepEqual(h.publications.map(p=>p.transport),['vless']);
});

test('failed native teardown cannot authorize alternate issuance',async()=>{
  const h=harness({stopFails:true,nativeError:()=>new Error('VPN connection failed')});
  await assert.rejects(h.flow.connectCurrentVpn());
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop']]);assert.equal(h.publications.length,0);
});

test('auto never benchmarks or flips an existing verified tunnel',async()=>{
  const h=harness({live:true});await h.flow.connectCurrentVpn();assert.deepEqual(h.events,[]);assert.equal(h.publications.length,0);
});

test('an old owner cannot issue an automatic alternate or publish',async()=>{
  let h;h=harness({profileError:()=>{h.invalidate();return failure('protocol_not_supported',501);}});
  await assert.rejects(h.flow.connectCurrentVpn(),/superseded/);
  assert.deepEqual(h.events,[['profile','amneziawg']]);assert.equal(h.publications.length,0);
});

test('auto remembers only a verified successful protocol rather than retrying a failed one',async()=>{
  const h=harness({nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  await h.flow.connectCurrentVpn();h.drop();h.events.length=0;
  await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','vless'],['native','vless'],['verified','vless']]);
});

for (const error of [Object.assign(new Error('VPN connection failed'),{code:'VPN_CONFIG_INVALID'}),
  Object.assign(new Error('VPN connection failed'),{code:'VPN_PROFILE_KEY_CHANGED'}),
  Object.assign(new Error('VPN connection failed'),{code:'SESSION_OPERATION_SUPERSEDED'}),
  Object.assign(new Error('VPN connect timed out'),{name:'TimeoutError'})]) {
  test(`auto never hides terminal native failures: ${error.code??error.name}`,async()=>{
    const h=harness({nativeError:()=>error});await assert.rejects(h.flow.connectCurrentVpn(),actual=>actual===error);
    assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg']]);assert.equal(h.publications.length,0);
  });
}

test('both native protocols failing exhausts the two-stage budget without publication',async()=>{
  const h=harness({nativeError:()=>new Error('VPN connection failed')});await assert.rejects(h.flow.connectCurrentVpn());
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop'],['profile','vless'],['native','vless'],['stop']]);
  assert.equal(h.publications.length,0);
});

test('native capability without VLESS stays AWG-only even in auto',async()=>{
  const h=harness({supported:false,nativeError:()=>new Error('VPN connection failed')});await assert.rejects(h.flow.connectCurrentVpn());
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop']]);assert.equal(h.publications.length,0);
});

for (const preference of ['amneziawg','vless']) test(`explicit ${preference} never falls across protocols after unavailability`,async()=>{
  const error=failure('protocol_unavailable',503);
  const h=harness({preference,profileError:()=>error});await assert.rejects(h.flow.connectCurrentVpn(),actual=>actual===error);
  assert.equal(h.events.length,1);assert.equal(h.publications.length,0);
});

test('cancellation while native work settles cannot publish or start the alternate',async()=>{
  let h;h=harness({nativeError:()=>{h.invalidate();return null;}});
  await assert.rejects(h.flow.connectCurrentVpn(),/superseded/);
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg']]);assert.equal(h.publications.length,0);
});

for(const option of ['invalidAddress','invalidKey']) test(`auto cannot relabel ${option} admission failure as a retryable native failure`,async()=>{
  const h=harness({[option]:true});await assert.rejects(h.flow.connectCurrentVpn());
  assert.deepEqual(h.events,[['profile','amneziawg']]);assert.equal(h.publications.length,0);
});

test('startup auto-connect waits for saved preference hydration before any work',()=>{
  const fs=require('node:fs'),ts=require('typescript'),vm=require('node:vm');
  const file='src/vpn/useVpnConnection.ts',source=fs.readFileSync(file,'utf8');
  const tree=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let effect;
  const visit=node=>{if(ts.isCallExpression(node)&&node.expression.getText(tree)==='useEffect'&&node.arguments[0].getText(tree).includes('getAndroidAutoConnectEnabled()'))effect=node.arguments[0].getText(tree);ts.forEachChild(node,visit);};
  visit(tree);assert.ok(effect);
  const code=ts.transpileModule('const effect='+effect+';effect();',{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
  vm.runInNewContext(code,{Platform:{OS:'android'},areVpnPreferencesHydrated:false,autoConnectAttemptedRef:{current:false},
    getAndroidAutoConnectEnabled:()=>assert.fail('preferences must hydrate first'),connectCurrentVpn:()=>assert.fail('premature connection')});
});

for(const nextPreference of ['auto','amneziawg']) test(`real preparation owner tracks saved preference, not auto's own concrete transition: ${nextPreference}`,async()=>{
  let finish,entered,cursor=0;const refs=[],writes=[];
  const gate=new Promise(resolve=>{finish=resolve;}),started=new Promise(resolve=>{entered=resolve;});
  const isCurrent=()=>true;
  const {useVpnProfileState:runProfileState}=loadWithBindings('src/vpn/useVpnProfileState.ts',null,{
    useRef:initial=>{const index=cursor++;return refs[index]??(refs[index]={current:initial});},
    useState:initial=>[initial,()=>{}],useMemo:fn=>fn(),useCallback:fn=>fn,useEffect:()=>{},
    useQueryClient:()=>({getQueryData:()=>null,setQueryData:(_key,value)=>writes.push(value)}),
    resolveVpnProfile:async()=>{entered();await gate;return {transport:'vless',config:'{}',locationId:'de',routingMode:'full_tunnel',source:'api'};},
  });
  const render=(preference,transport)=>{cursor=0;return runProfileState({transportPreference:preference,transport,routingMode:'full_tunnel',
    accessToken:'fixture',knownEntitlement:{active:true,vpnAccess:true},selectedLocationId:'de',isCurrentSessionOperation:isCurrent});};
  const first=render('auto','amneziawg');
  const pending=first.resolveConnectableVpnProfile('de',{transport:'vless',forceRefresh:true,requestPermission:false});
  await started;render(nextPreference,nextPreference==='auto'?'vless':'amneziawg');finish();
  if(nextPreference==='auto'){assert.equal((await pending).transport,'vless');assert.equal(writes.length,1);}
  else {await assert.rejects(pending,/superseded/);assert.equal(writes.length,0);}
});

test('real auto profile hook never starts speculative profile queries or a refresh timer',()=>{
  const effects=[];
  const {useVpnProfileState:runProfileState}=loadWithBindings('src/vpn/useVpnProfileState.ts',null,{
    useRef:current=>({current}),useState:initial=>[initial,()=>{}],useMemo:fn=>fn(),useCallback:fn=>fn,useEffect:fn=>effects.push(fn),
    useQueryClient:()=>({fetchQuery:()=>assert.fail('auto cannot issue a speculative profile'),getQueryData:()=>null}),
  },{setInterval:()=>assert.fail('auto cannot schedule profile issuance')});
  runProfileState({transportPreference:'auto',transport:'amneziawg',routingMode:'full_tunnel',accessToken:'fixture',
    selectedLocationId:'de',hasVpnAccess:true,isCurrentSessionOperation:()=>true});
  for(const effect of effects)assert.equal(effect(),undefined);
});

test('a fresh verified native tunnel also prevents automatic benchmarking before JS catches up',async()=>{
  const h=harness({nativeLive:true});await h.flow.connectCurrentVpn();assert.deepEqual(h.events,[]);assert.equal(h.publications.length,0);
});

test('actual Android VPN_CONNECT_FAILED codes still permit a genuine retryable native path',async()=>{
  const h=harness({nativeError:protocol=>protocol==='amneziawg'?Object.assign(new Error('connection refused'),{code:'VPN_CONNECT_FAILED'}):null});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.publications.map(p=>p.transport),['vless']);
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop'],['profile','vless'],['native','vless'],['verified','vless']]);
});

test('the native catch-all code does not make unknown local faults retryable',async()=>{
  const h=harness({nativeError:()=>Object.assign(new Error('VPN protection could not be retained'),{code:'VPN_CONNECT_FAILED'})});
  await assert.rejects(h.flow.connectCurrentVpn());assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg']]);assert.equal(h.publications.length,0);
});

test('a remembered VLESS 503 after token issuance cannot issue AWG or publish another connection',async()=>{
  let committed=false,writes=0;const error=failure('vless_unavailable',503);
  const h=harness({profileError:protocol=>{if(committed&&protocol==='vless'){writes++;return error;}return null;},
    nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  await h.flow.connectCurrentVpn();h.drop();h.events.length=0;h.publications.length=0;committed=true;
  await assert.rejects(h.flow.connectCurrentVpn(),actual=>actual===error);
  assert.equal(writes,1);assert.deepEqual(h.events,[['profile','vless']]);assert.equal(h.publications.length,0);
});

// Exact Android WireGuardController.disconnect(false) -> Blocking wire DTO.
const settledBlocking={state:'error',leakProtection:'blocking',verified:false,rxBytes:0,txBytes:0,
  latestHandshakeEpochMillis:0,verificationReason:'endpoint_failed'};

test('a settled protected Android disconnect permits serial alternate dispatch without releasing lockdown',async()=>{
  let release,reached;
  const gate=new Promise(resolve=>{release=resolve;}),stopping=new Promise(resolve=>{reached=resolve;});
  const h=harness({nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null,
    settledDisconnect:settledBlocking,disconnectWait:()=>{reached();return gate;}});
  const pending=h.flow.connectCurrentVpn();await stopping;
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop']]);
  assert.equal(h.publications.length,0);release();await pending;
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop'],['profile','vless'],['native','vless'],['verified','vless']]);
  assert.deepEqual(h.publications.map(profile=>profile.transport),['vless']);
  assert.deepEqual(h.disconnectOptions,[{releaseAntiLeak:false}]);
});

test('an initial blocker is not considered stopped until its own disconnect promise settles',async()=>{
  let release,reached;
  const gate=new Promise(resolve=>{release=resolve;}),stopping=new Promise(resolve=>{reached=resolve;});
  const h=harness({initialStatus:settledBlocking,settledDisconnect:settledBlocking,disconnectWait:()=>{reached();return gate;}});
  const pending=h.flow.connectCurrentVpn();await stopping;assert.deepEqual(h.events,[['stop']]);release();await pending;
  assert.deepEqual(h.events,[['stop'],['profile','amneziawg'],['native','amneziawg'],['verified','amneziawg']]);
  assert.deepEqual(h.disconnectOptions,[{releaseAntiLeak:false}]);
});

for (const [name,patch] of [
  ['unknown state',{state:'unknown'}],['live connected',{state:'connected'}],['degraded',{state:'degraded'}],
  ['connecting',{state:'connecting'}],['verifying',{state:'verifying'}],['disconnecting',{state:'disconnecting'}],
  ['nonzero rx',{rxBytes:1}],['nonzero tx',{txBytes:1}],['missing rx',{rxBytes:undefined}],
  ['NaN rx',{rxBytes:NaN}],['live handshake',{latestHandshakeEpochMillis:Date.now()}],
  ['unknown handshake',{latestHandshakeEpochMillis:undefined}],['verified',{verified:true}],
  ['unknown verification',{verified:undefined}],['unprotected error',{leakProtection:'off'}],
  ['armed error',{leakProtection:'armed'}],['unknown reason',{verificationReason:undefined}],
]) for (const entry of ['retry','initial']) {
  test(`${entry} rejects non-quiescent protected teardown: ${name}`,async()=>{
    const h=harness({initialStatus:entry==='initial'?settledBlocking:undefined,
      settledDisconnect:{...settledBlocking,...patch},nativeError:()=>new Error('VPN connection failed')});
    await assert.rejects(h.flow.connectCurrentVpn());
    assert.deepEqual(h.events,entry==='initial'?[['stop']]:[['profile','amneziawg'],['native','amneziawg'],['stop']]);
    assert.equal(h.publications.length,0);
  });
}


const networkA={networkClass:'wifi',generation:'11111111-1111-1111-1111-111111111111'};
const qualifiedCatalog=[
  {id:'nl',latencyMs:6,availability:'available',status:'active',healthyNodes:1,capabilities:['vless-xhttp-v1']},
  {id:'fi',latencyMs:8,availability:'available',status:'active',healthyNodes:1,capabilities:['vless-xhttp-v1']},
];
async function qualifiedHarness(options={}) {
  let observed=networkA,time=Date.now();
  const h=harness({preference:'amneziawg',selectedLocationId:'fi',serverSelectionMode:'manual',
    availableLocations:qualifiedCatalog,observation:()=>observed,now:()=>time,...options});
  h.observe=value=>{observed=value;};h.advance=ms=>{time+=ms;};
  await h.flow.connectCurrentVpn();h.drop();h.events.length=0;h.locations.length=0;
  h.render({transportPreference:'auto',serverSelectionMode:'auto'});return h;
}

test('next serverAuto prefers actual verified manual FI over faster catalog NL without extra issuance',async()=>{
  const h=await qualifiedHarness();await h.flow.connectCurrentVpn();
  assert.deepEqual(h.locations,['fi']);
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['verified','amneziawg']]);
});

test('qualified location is also preferred with explicit protocol and serverAuto',async()=>{
  const h=await qualifiedHarness();h.render({transportPreference:'amneziawg'});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['fi']);
});

for(const [name,change] of [
  ['generation changed',h=>h.observe({...networkA,generation:'22222222-2222-2222-2222-222222222222'})],
  ['class changed',h=>h.observe({...networkA,networkClass:'cellular'})],
  ['unknown',h=>h.observe({networkClass:'unknown',generation:''})],
  ['missing generation',h=>h.observe({...networkA,generation:''})],
  ['expired',h=>h.advance(300001)],['clock moved backwards',h=>h.advance(-1)],
  ['owner changed',h=>h.render({session:{accessToken:'fixture',user:{id:'other'}}})],
  ['session changed',h=>h.render({isCurrentSessionOperation:()=>true})],
  ['logged out',h=>h.render({session:null})],
  ['removed from catalog',h=>h.render({availableLocations:[qualifiedCatalog[0]]})],
  ['unavailable',h=>h.render({availableLocations:[qualifiedCatalog[0],{...qualifiedCatalog[1],availability:'unavailable'}]})],
  ['unhealthy',h=>h.render({availableLocations:[qualifiedCatalog[0],{...qualifiedCatalog[1],healthyNodes:0}]})],
  ['protocol changed',h=>h.render({transportPreference:'vless'})],
]) test(`unqualified location uses existing catalog policy: ${name}`,async()=>{
  const h=await qualifiedHarness();change(h);
  // Owner changes may correctly fail key admission, but selection is still observable.
  await h.flow.connectCurrentVpn().catch(error=>{if(!['owner changed','logged out'].includes(name))throw error;});
  assert.deepEqual(h.locations,['nl']);
});

for(const stage of ['before','after']) test(`no seed when generation changes ${stage} verified success`,async()=>{
  let reads=0;
  const h=await qualifiedHarness({observation:async()=>{
    reads++;return reads===(stage==='before'?1:2)?{...networkA,generation:'22222222-2222-2222-2222-222222222222'}:networkA;
  }});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

for(const result of ['unknown','reject','hang']) test(`optional observation ${result} cannot prevent a bounded successful connect`,async()=>{
  const start=Date.now();
  const h=await qualifiedHarness({observation:()=>result==='hang'?new Promise(()=>{}):result==='reject'?Promise.reject(new Error('optional unavailable')):{networkClass:'unknown',generation:''}});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);assert.ok(Date.now()-start<3000);
  assert.equal(h.publications.length,2);
});

test('actual returned profile location rather than requested location supplies the evidence',async()=>{
  const h=await qualifiedHarness({selectedLocationId:'nl',actualLocation:'fi'});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['fi']);
});

test('explicit manual server is not overridden by qualified evidence',async()=>{
  const h=await qualifiedHarness();h.render({serverSelectionMode:'manual',selectedLocationId:'nl'});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

test('explicit location argument is not overridden by qualified evidence or RTT',async()=>{
  const h=await qualifiedHarness();await h.flow.connectCurrentVpn({locationId:'fi'});assert.deepEqual(h.locations,['fi']);
});

test('failed qualified attempt cannot be preferred again on a later connect',async()=>{
  let fail=false;
  const h=await qualifiedHarness({profileError:()=>fail?failure('forbidden',403):null});fail=true;
  await assert.rejects(h.flow.connectCurrentVpn());assert.deepEqual(h.locations,['fi']);
  fail=false;h.locations.length=0;await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

test('network mismatch consumes old evidence rather than resurrecting it after failure',async()=>{
  let fail=false;
  const h=await qualifiedHarness({profileError:()=>fail?failure('forbidden',403):null});
  h.observe({...networkA,networkClass:'cellular'});fail=true;await assert.rejects(h.flow.connectCurrentVpn());
  h.observe(networkA);fail=false;h.locations.length=0;
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

test('cancellation during post-success observation cannot publish or seed location evidence',async()=>{
  let reads=0,h;
  h=harness({preference:'amneziawg',selectedLocationId:'fi',availableLocations:qualifiedCatalog,
    observation:()=>{if(++reads===2)h.invalidate();return networkA;}});
  await assert.rejects(h.flow.connectCurrentVpn(),/superseded/);assert.equal(h.publications.length,0);
});


for (const stage of [1,2,3]) test(`unknown observation on read ${stage} cannot qualify or retain FI`,async()=>{
  let reads=0;
  const h=await qualifiedHarness({observation:()=>++reads===stage?{networkClass:'unknown',generation:''}:networkA});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

for (const result of ['reject','hang']) test(`bounded ${result} on later read discards previously qualified FI`,async()=>{
  let reads=0;
  const h=await qualifiedHarness({observation:()=>++reads===3
    ?result==='hang'?new Promise(()=>{}):Promise.reject(new Error('optional failure')):networkA});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

test('actual verified automatic VLESS success qualifies only that transport on the next auto',async()=>{
  const h=await qualifiedHarness({preference:'auto',nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['fi']);
  assert.deepEqual(h.events,[['profile','vless'],['native','vless'],['verified','vless']]);
});

test('a successful profile absent from the seed catalog is not qualified when it later becomes selectable',async()=>{
  const h=await qualifiedHarness({selectedLocationId:'nl',actualLocation:'fi',availableLocations:[qualifiedCatalog[0]]});
  h.render({availableLocations:qualifiedCatalog});await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

for (const delta of [-1,300001]) test(`clock jump during success does not seed location: ${delta}`,async()=>{
  let reads=0,time=Date.now();
  const h=await qualifiedHarness({now:()=>time,observation:()=>{if(++reads===2)time+=delta;return networkA;}});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
});

test('token refresh within the same session preserves qualified evidence',async()=>{
  const h=await qualifiedHarness();h.render({session:{accessToken:'refreshed-fixture',user:{id:'owner'}}});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['fi']);
});

test('auto with a live verified tunnel never reads optional network observation',async()=>{
  const h=harness({nativeLive:true,observation:()=>assert.fail('no active-tunnel benchmarking')});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.events,[]);
});


for (const supportsVless of [false,undefined]) {
  for (const outcome of ['success','profile unavailable','native failure']) {
    test(`automatic VLESS unavailable (${supportsVless}): ${outcome} stays AWG-only`,async()=>{
      const h=harness({supportsVless,
        profileError:()=>outcome==='profile unavailable'?failure('protocol_not_supported',501):null,
        nativeError:()=>outcome==='native failure'?new Error('VPN connection failed'):null});
      if(outcome==='success')await h.flow.connectCurrentVpn();
      else await assert.rejects(h.flow.connectCurrentVpn());
      assert.deepEqual(h.events,outcome==='success'
        ?[['profile','amneziawg'],['native','amneziawg'],['verified','amneziawg']]
        :outcome==='profile unavailable'?[['profile','amneziawg']]
          :[['profile','amneziawg'],['native','amneziawg'],['stop']]);
    });
  }
  test(`historical VLESS success cannot select VLESS after availability becomes ${supportsVless}`,async()=>{
    let failAwg=true;
    const h=harness({nativeError:protocol=>failAwg&&protocol==='amneziawg'?new Error('VPN connection failed'):null});
    await h.flow.connectCurrentVpn();assert.equal(h.publications.at(-1).transport,'vless');
    h.drop();h.events.length=0;failAwg=false;h.render({supportsVless});
    await h.flow.connectCurrentVpn();
    assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['verified','amneziawg']]);
  });
}

test('restoring positive VLESS availability restores the remembered eligible protocol',async()=>{
  let withdrawn=false;
  const h=harness({nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null,
    profileError:()=>withdrawn?failure('protocol_not_supported',501):null});
  await h.flow.connectCurrentVpn();assert.equal(h.publications.at(-1).transport,'vless');
  h.drop();h.events.length=0;withdrawn=true;h.render({supportsVless:false});
  await assert.rejects(h.flow.connectCurrentVpn());assert.deepEqual(h.events,[['profile','amneziawg']]);
  h.events.length=0;withdrawn=false;h.render({supportsVless:true});
  await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','vless'],['native','vless'],['verified','vless']]);
});

for(const statusSource of ['JS','native']) test(`withdrawn VLESS availability never replaces a healthy verified ${statusSource} tunnel`,async()=>{
  const h=harness({supportsVless:false,...(statusSource==='JS'?{live:true}:{nativeLive:true})});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.events,[]);
});


const vlessOnlyFiCatalog=[
  {...qualifiedCatalog[0],capabilities:[]},
  qualifiedCatalog[1],
  {id:'offline',latencyMs:1,availability:'available',status:'active',healthyNodes:0,capabilities:['vless-xhttp-v1']},
];

test('serverAuto serial VLESS fallback chooses capable FI rather than faster AWG-only NL',async()=>{
  const h=harness({serverSelectionMode:'auto',availableLocations:vlessOnlyFiCatalog,
    nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl','fi']);
  assert.deepEqual(h.events,[['profile','amneziawg'],['native','amneziawg'],['stop'],['profile','vless'],['native','vless'],['verified','vless']]);
});

test('explicit VLESS with serverAuto chooses only healthy capability-advertising locations',async()=>{
  const h=harness({preference:'vless',serverSelectionMode:'auto',availableLocations:vlessOnlyFiCatalog});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['fi']);
  assert.deepEqual(h.events,[['profile','vless'],['native','vless'],['verified','vless']]);
});

test('qualified VLESS location loses priority when its advertised capability is withdrawn',async()=>{
  const h=await qualifiedHarness({preference:'auto',nativeError:protocol=>protocol==='amneziawg'?new Error('VPN connection failed'):null});
  h.render({availableLocations:[qualifiedCatalog[0],{...qualifiedCatalog[1],capabilities:[]}]});
  await h.flow.connectCurrentVpn();assert.deepEqual(h.locations,['nl']);
  assert.deepEqual(h.events,[['profile','vless'],['native','vless'],['verified','vless']]);
});

for(const capabilities of [undefined,[],['vless'],['vless-xhttp-v0']]) test(`serverAuto VLESS cannot issue on an unadvertised catalog: ${JSON.stringify(capabilities)}`,async()=>{
  const h=harness({preference:'vless',serverSelectionMode:'auto',availableLocations:qualifiedCatalog.map(location=>({...location,capabilities}))});
  await assert.rejects(h.flow.connectCurrentVpn());assert.deepEqual(h.events,[]);assert.deepEqual(h.locations,[]);
});


function deferred() {
  let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};
}
const withdrawalCatalog=[{id:'de',availability:'available',status:'active',healthyNodes:1,capabilities:['vless-xhttp-v1']}];
for(const withdrawal of ['support','capability','location health']) for(const stage of ['before alternate issuance','pending VLESS reply','after identity admission']) {
  test(`in-flight auto stops VLESS ${stage} on latest ${withdrawal} withdrawal`,async()=>{
    const entered=deferred(),release=deferred();
    const h=harness({availableLocations:withdrawalCatalog,
      profileError:async protocol=>{
        if((stage==='before alternate issuance'&&protocol==='amneziawg')||(stage==='pending VLESS reply'&&protocol==='vless')) {
          entered.resolve();await release.promise;
        }
        return protocol==='amneziawg'?failure('protocol_not_supported',501):null;
      },
      ...(stage==='after identity admission'?{nativeAdmissionWait:async profile=>{
        if(profile.transport==='vless'){entered.resolve();await release.promise;}
      }}:{}),
    });
    const pending=h.flow.connectCurrentVpn();await entered.promise;
    h.render(withdrawal==='support'?{supportsVless:false}:{availableLocations:withdrawalCatalog.map(location=>({...location,
      ...(withdrawal==='capability'?{capabilities:[]}:{healthyNodes:0})}))});
    release.resolve();await assert.rejects(pending,error=>error.code==='VPN_VLESS_UNAVAILABLE');
    assert.deepEqual(h.events,stage==='before alternate issuance'?[['profile','amneziawg']]:[['profile','amneziawg'],['profile','vless']]);
    assert.equal(h.publications.length,0);
  });
}

test('a later explicit operation can use freshly restored support and catalog after terminal withdrawal',async()=>{
  const entered=deferred(),release=deferred();let pause=true;
  const h=harness({availableLocations:withdrawalCatalog,profileError:async protocol=>{
    if(protocol==='amneziawg'){
      if(pause){entered.resolve();await release.promise;}
      return failure('protocol_not_supported',501);
    }
    return null;
  }});
  const pending=h.flow.connectCurrentVpn();await entered.promise;h.render({supportsVless:false,availableLocations:[]});release.resolve();
  await assert.rejects(pending,error=>error.code==='VPN_VLESS_UNAVAILABLE');
  pause=false;h.events.length=0;h.render({supportsVless:true,availableLocations:withdrawalCatalog});
  await h.flow.connectCurrentVpn();
  assert.deepEqual(h.events,[['profile','amneziawg'],['profile','vless'],['native','vless'],['verified','vless']]);
});

for(const ownerChange of ['owner','session']) test(`latest availability cannot lend another ${ownerChange} to an old native admission`,async()=>{
  const entered=deferred(),release=deferred();
  const h=harness({availableLocations:withdrawalCatalog,profileError:protocol=>protocol==='amneziawg'?failure('protocol_not_supported',501):null,
    nativeAdmissionWait:async()=>{entered.resolve();await release.promise;}});
  const pending=h.flow.connectCurrentVpn();await entered.promise;
  h.render(ownerChange==='owner'?{session:{accessToken:'fixture',user:{id:'other'}}}:{isCurrentSessionOperation:()=>true});
  release.resolve();await assert.rejects(pending,/superseded/);
  assert.deepEqual(h.events,[['profile','amneziawg'],['profile','vless']]);assert.equal(h.publications.length,0);
});
