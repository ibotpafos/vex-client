import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { client, settle, ok, failure, primary, fallback } from './helpers/dual-origin-client.mjs';

for (const path of ['/v1/billing/entitlement', '/v1/vpn/profile?device_id=fixture', '/v1/auth/me']) {
  test(`pre-VPN read fails over after network failure: ${path}`, async () => {
    const calls = [];
    const api = client(async (url, init) => {
      calls.push([url, init]);
      if (url.startsWith(primary)) throw new TypeError('Network request failed');
      return ok('authorized server result');
    });
    assert.equal(await api.rawRequest(path, {accessToken: 'fixture'}), 'authorized server result');
    assert.deepEqual(calls.map(([url]) => url), [primary + path, fallback + path]);
    for (const [,init] of calls) { assert.equal(init.headers.Authorization, 'Bearer fixture'); assert.equal(init.redirect, 'error'); assert.equal(init.credentials, 'omit'); }
  });
}

test('stalled primary is cancelled; fallback and later primary recovery are deterministic', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'], now:0});
  const calls = []; let primaryHealthy = false;
  const api = client(async (url, init) => {
    calls.push([url, init.signal]);
    if (url.startsWith(primary) && !primaryHealthy) return new Promise(() => {});
    return ok();
  });
  const first = api.rawRequest('/v1/vpn/profile', {timeout:1000});
  await settle(); t.mock.timers.tick(499); await settle(); assert.equal(calls.length,1);
  t.mock.timers.tick(1); await settle(); assert.equal(await first,'ok');
  assert.equal(calls[0][1].aborted,true);
  primaryHealthy = true; assert.equal(await api.rawRequest('/v1/vpn/profile'),'ok');
  assert.deepEqual(calls.map(([url]) => url), [primary, fallback, primary].map(origin => origin+'/v1/vpn/profile'));
});

test('all attempts and ignored aborts share one whole deadline', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'], now:0});
  const calls = []; const api = client((url, init) => {calls.push([url,init.signal]); return new Promise(()=>{});});
  const result = assert.rejects(api.rawRequest('/v1/vpn/profile',{timeout:1000}), e => e.code==='request_timeout');
  await settle();t.mock.timers.tick(500);await settle();assert.equal(calls.length,2);
  t.mock.timers.tick(500);await settle();await result;
  assert.ok(calls.every(([,signal])=>signal.aborted));
  t.mock.timers.tick(10000);await settle();assert.equal(calls.length,2);
});

for (const when of ['before','fetch','backoff']) test(`caller abort settles and prevents later I/O: ${when}`, async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0;const abort=new AbortController();
  const api=client(async()=>{calls++;if(when==='backoff') return failure(503); return new Promise(()=>{});});
  if(when==='before')abort.abort();
  const result=assert.rejects(api.rawRequest('/v1/vpn/profile',{signal:abort.signal}),e=>e.code==='request_aborted');
  await settle();abort.abort();await settle();await result;
  const count=calls;t.mock.timers.tick(60000);await settle();assert.equal(calls,count);if(when==='before')assert.equal(calls,0);
});

for (const status of [401,403,409,429,502,503,504]) test(`HTTP ${status} never switches origins`, async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const calls=[];const api=client(async url=>{calls.push(url);return failure(status);});
  const result=assert.rejects(api.rawRequest('/v1/vpn/profile'),e=>e.status===status);
  await settle();for(const ms of [600,1200,30000]){t.mock.timers.tick(ms);await settle();}await result;
  assert.ok(calls.every(url=>url.startsWith(primary)));
});

test('maintenance code is terminal and a stalled denial body cannot escape to fallback',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0;let api=client(async()=>{calls++;return failure(503,'maintenance');});
  await assert.rejects(api.rawRequest('/v1/vpn/profile'));assert.equal(calls,1);
  calls=0;api=client(async()=>{calls++;return {ok:false,status:403,text:()=>new Promise(()=>{})};});
  const result=assert.rejects(api.rawRequest('/v1/vpn/profile',{timeout:1000}),e=>e.status===403);
  await settle();t.mock.timers.tick(500);await settle();await result;assert.equal(calls,1);
});

for(const method of ['POST','PUT','PATCH','DELETE','post']) test(`${method} never replays even with idempotency key`,async()=>{
  const calls=[];const api=client(async(url,init)=>{if(init.method==='GET')return ok();calls.push([url,init]);throw new TypeError('Network request failed');});
  await assert.rejects(api.rawRequest('/v1/devices/register',{method,idempotencyKey:'fixture',body:{key:'fixture'}}));
  assert.equal(calls.length,1);assert.equal(calls[0][1].headers['Idempotency-Key'],'fixture');
});

for(const path of ['https://evil.test/v1/profile','//evil.test/v1/profile','/v1/../admin','/v1/%2e%2e/admin','/v1/%252e%252e/admin','/v1/%2fadmin','/v1/\\evil','/v1/profile#fragment']) test(`unsafe path never sends credentials: ${path}`,async()=>{
  const api=client(()=>assert.fail('must not fetch'));
  await assert.rejects(api.rawRequest(path,{accessToken:'fixture'}));
});

test('redirect replies fail closed without a second origin',async()=>{
  for(const response of [{ok:false,status:302,text:async()=>'',headers:{get:()=> 'https://evil.test'}}, {...ok(),redirected:true,url:'https://evil.test/v1/profile'}]) {
    let calls=0;const api=client(async()=>{calls++;return response;});
    await assert.rejects(api.rawRequest('/v1/vpn/profile',{accessToken:'fixture'}),e=>e.code==='unsafe_redirect');assert.equal(calls,1);
  }
});

test('native requests use Expo Fetch with redirect rejection and no cookies, never RN Fetch/XHR',async()=>{
  for(const platform of ['android','ios']) {
    const calls=[];
    const api=client(()=>assert.fail('unsafe RN Fetch'),{platform,expoFetch:async(url,init)=>{calls.push([url,init]);return ok();}});
    assert.equal(await api.rawRequest('/v1/auth/me',{accessToken:'fixture'}),'ok');
    assert.equal(calls.length,1);assert.ok(calls.every(([,init])=>init.redirect==='error'&&init.credentials==='omit'));assert.equal(calls[0][1].method,'GET');
  }
});

test('Expo native DNS failure fails over; redirect exceptions never do',async()=>{
  for(const platform of ['android','ios']) {
    const calls=[];
    const api=client(()=>assert.fail('RN Fetch'),{platform,expoFetch:async(url)=>{calls.push(url);if(calls.length===1)throw new Error('fetch failed: native DNS unavailable');return ok();}});
    assert.equal(await api.rawRequest('/v1/vpn/profile',{accessToken:'fixture'}),'ok');
    assert.deepEqual(calls,[primary,fallback].map(origin=>origin+'/v1/vpn/profile'));
    let count=0;
    const redirect=client(()=>assert.fail('RN Fetch'),{platform,expoFetch:async()=>{count++;throw new Error('fetch failed: Redirect is not allowed');}});
    await assert.rejects(redirect.rawRequest('/v1/vpn/profile',{accessToken:'fixture'}),e=>e.code==='unsafe_redirect');assert.equal(count,1);
  }
});

test('fixed production roots, isolated dev proxy and canonical callback base',async()=>{
  for(const env of [{}, {EXPO_PUBLIC_VEX_API_BASE_URL:'https://vexguard.app'}, {EXPO_PUBLIC_VEX_API_ORIGIN:fallback}]) {
    let url;const api=client(async value=>{url=value;return ok();},{env});await api.rawRequest('/v1/auth/me');assert.equal(url,primary+'/v1/auth/me');assert.equal(api.vexApiBaseUrl,'https://vexguard.app');
  }
  for(const base of ['https://evil.test','http://api.vexguard.app','https://api.vexguard.app:444','https://user:pass@api.vexguard.app','https://api2.vexguard.app/path'])assert.throws(()=>client(()=>{}, {env:{EXPO_PUBLIC_VEX_API_ORIGIN:base}}));
  const calls=[];const api=client(async url=>{calls.push(url);throw new TypeError('Network request failed');},{env:{EXPO_PUBLIC_VEX_API_BASE_URL:'http://localhost:3011',EXPO_PUBLIC_VEX_API_ORIGIN:primary}});
  await assert.rejects(api.rawRequest('/v1/auth/me',{retryCount:0}));assert.deepEqual(calls,['http://localhost:3011/v1/auth/me']);
});

test('API roots cannot expand artifact trust; canonical signed downloads stay valid',()=>{
  const origins=stripTypeScriptTypes(fs.readFileSync('src/api/origins.ts','utf8')).replace(/\bexport /g,'');
  const source=stripTypeScriptTypes(fs.readFileSync('src/api/updatePreflight.ts','utf8')).replace(/^import .*;$/gm,'').replace(/\bexport /g,'');
  const validate=new Function(origins+source+';return validateManualUpdatePayloadForBaseUrl;')();
  const payload=origin=>({downloadUrl:origin+'/downloads/Vex.apk',signatureUrl:origin+'/downloads/Vex.apk.sig',checksumSha256:'a'.repeat(64)});
  for(const base of [primary,fallback,'https://vexguard.app']) {
    assert.equal(validate(payload('https://vexguard.app'),base).ok,true);
    for(const origin of [primary,fallback,'https://evil.test','https://user:pass@vexguard.app'])assert.equal(validate(payload(origin),base).ok,false);
  }
  const install=fs.readFileSync('src/api/manualUpdateInstall.ts','utf8');assert.ok(!install.includes('EXPO_PUBLIC_VEX_API_'));
  const config=fs.readFileSync('app.config.ts','utf8');assert.match(config,/https:\/\/updates\.vexguard\.app\/manifest/);
});

for(const path of ['/v1/auth/login','/v1/devices/register'])test(`cold mutation selects reserve safely before its only send: ${path}`,async()=>{
  const calls=[];
  const api=client(async(url,init)=>{calls.push([url,init]);if(url.startsWith(primary))throw new TypeError('Network request failed');return ok();});
  const body={password:'fixture',public_key:'fixture'};
  assert.equal(await api.rawRequest(path,{method:'POST',accessToken:'fixture-token',idempotencyKey:'fixture-key',headers:{'X-Private':'fixture'},body}),'ok');
  assert.deepEqual(calls.map(([url,init])=>[url,init.method]),[[primary+'/v1/billing/plans','GET'],[fallback+'/v1/billing/plans','GET'],[fallback+path,'POST']]);
  for(const [,probe] of calls.slice(0,2)){assert.deepEqual(probe.headers,{Accept:'application/json'});assert.equal(probe.body,undefined);}
  const sent=calls[2][1];assert.equal(sent.body,JSON.stringify(body));assert.equal(sent.headers.Authorization,'Bearer fixture-token');assert.equal(sent.headers['Idempotency-Key'],'fixture-key');assert.equal(sent.headers['X-Private'],'fixture');
});

for(const status of [401,403,429,503])test(`mutation probe HTTP ${status} never sends a mutation or tries reserve`,async()=>{
  const calls=[];const api=client(async(url,init)=>{calls.push([url,init]);return failure(status);});
  await assert.rejects(api.rawRequest('/v1/auth/login',{method:'POST',body:{password:'fixture'}}),e=>e.status===status);
  assert.equal(calls.length,1);assert.equal(calls[0][1].method,'GET');assert.ok(calls[0][0].startsWith(primary));
});

test('mutation probe and single send share one deadline, including primary timeout and ignored abort',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const calls=[];
  const api=client(async(url,init)=>{calls.push([url,init]);if(url.startsWith(primary)||init.method==='POST')return new Promise(()=>{});return ok();});
  const result=assert.rejects(api.rawRequest('/v1/devices/register',{method:'POST',timeout:1200,idempotencyKey:'fixture',body:{}}),e=>e.code==='request_timeout');
  await settle();t.mock.timers.tick(400);await settle();assert.equal(calls.length,3);assert.equal(calls[0][1].signal.aborted,true);
  t.mock.timers.tick(800);await settle();await result;t.mock.timers.tick(10000);await settle();assert.equal(calls.filter(([,init])=>init.method==='POST').length,1);
});

test('explicit Expo Fetch import cannot switch to global RN Fetch through env',()=>{
  const source=fs.readFileSync('src/api/client.ts','utf8');
  assert.match(source,/import \{ fetch as expoFetch \} from 'expo\/fetch'/);
  assert.match(source,/Platform\.OS === 'web' \? fetch : expoFetch/);
  assert.ok(!source.includes('EXPO_PUBLIC_USE_RN_FETCH'));
  assert.match(source,/const shouldLogApiRequests = Platform\.OS === 'web'/);
});

for(const status of [401,403,429,503])test(`a broken HTTP ${status} body never becomes cross-origin network failover`,async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const calls=[];const api=client(async url=>{calls.push(url);return {ok:false,status,text:async()=>{throw new TypeError('Network request failed');}};});
  const result=assert.rejects(api.rawRequest('/v1/vpn/profile'),e=>e.status===status);
  await settle();for(const ms of [600,1200,30000]){t.mock.timers.tick(ms);await settle();}await result;assert.ok(calls.every(url=>url.startsWith(primary)));
});

test('revocation and account/traffic limits are returned verbatim without alternate-origin authorization',async()=>{
  for(const body of [{revoked:true},{active:false,vpn_access:false},{limit_reached:true,effective_rate_limit_mbps:1}]) {
    const calls=[];const encoded=JSON.stringify(body);const api=client(async url=>{calls.push(url);return ok(encoded);});
    assert.equal(await api.rawRequest('/v1/vpn/profile',{accessToken:'fixture'}),encoded);assert.equal(calls.length,1);
  }
});

test('mutation primary recovery is re-probed on every operation without replay',async()=>{
  let healthy=false;const calls=[];
  const api=client(async(url,init)=>{calls.push([url,init.method]);if(!healthy&&url.startsWith(primary))throw new TypeError('Network request failed');return ok();});
  await api.rawRequest('/v1/auth/login',{method:'POST',body:{password:'fixture'}});healthy=true;
  await api.rawRequest('/v1/devices/register',{method:'POST',idempotencyKey:'fixture',body:{}});
  assert.deepEqual(calls.filter(([,method])=>method==='POST'),[[fallback+'/v1/auth/login','POST'],[primary+'/v1/devices/register','POST']]);
});

test('manual installer keeps canonical artifact trust independently of API env (mocked download/install only)',async()=>{
  const read=path=>stripTypeScriptTypes(fs.readFileSync(path,'utf8')).replace(/^import .*;$/gm,'').replace(/\bexport /g,'');
  const install=new Function('process',read('src/api/origins.ts')+read('src/api/updatePreflight.ts')+'const defaultTrustedUpdateBaseUrl = trustedUpdateBaseUrl;'+read('src/api/manualUpdateInstall.ts')+';return installManualUpdate;')({env:{EXPO_PUBLIC_VEX_API_BASE_URL:primary,EXPO_PUBLIC_VEX_API_ORIGIN:fallback}});
  const downloaded=[];const deps={downloadAndroidUpdateApk:async url=>{downloaded.push(url);return {filePath:'mock-only'};},installAndroidUpdateApk:async()=>({status:'mock-only'})};
  const update=origin=>({updateAvailable:true,downloadUrl:origin+'/downloads/Vex.apk',signatureUrl:origin+'/downloads/Vex.apk.sig',checksumSha256:'a'.repeat(64)});
  for(const origin of [primary,fallback])await assert.rejects(install(update(origin),'android',deps));
  assert.equal(downloaded.length,0);assert.equal((await install(update('https://vexguard.app'),'android',deps)).status,'mock-only');assert.equal(downloaded.length,1);
});

for (const method of ['POST','PUT','PATCH','DELETE','post']) test(`Android ${method} requires no-replay ABI before probes or credential setup`, async () => {
  for (const native of [{}, {apiMutationNoReplay:true}, {apiMutationNoReplay:false,requestApiMutation(){assert.fail('unsafe capability');},cancelApiMutation(){}}]) {
    let metadata=0;
    const api=client(()=>assert.fail('RN Fetch'),{platform:'android',native,expoFetch:()=>assert.fail('probe/Expo credential I/O'),appInfo:async()=>{metadata++;return {};}});
    await assert.rejects(api.rawRequest('/v1/auth/login',{method,accessToken:'fixture',idempotencyKey:'fixture-key',body:{password:'fixture'}}),e=>e.code==='native_transport_update_required');
    assert.equal(metadata,0);
  }
});

test('Android cold login probes without credentials then sends only through no-replay default-route ABI',async()=>{
  const probes=[],mutations=[];
  const native={apiMutationNoReplay:true,requestApiMutation:async(...args)=>{mutations.push(args);return {status:200,body:'logged in',headers:{}};},cancelApiMutation(){}};
  const api=client(()=>assert.fail('global Fetch'),{platform:'android',native,expoFetch:async(url,init)=>{
    probes.push([url,init]);assert.equal(init.method,'GET');assert.deepEqual(init.headers,{Accept:'application/json'});
    if(url.startsWith(primary))throw new Error('fetch failed: unable to resolve host');return ok();
  }});
  assert.equal(await api.rawRequest('/v1/auth/login',{method:'POST',accessToken:'fixture-token',idempotencyKey:'fixture-key',body:{password:'fixture'}}),'logged in');
  assert.equal(probes.length,2);assert.equal(mutations.length,1);
  const [,url,method,headers,body,deadline]=mutations[0];
  assert.equal(url,fallback+'/v1/auth/login');assert.equal(method,'POST');assert.equal(body,'{"password":"fixture"}');assert.equal(headers.Authorization,'Bearer fixture-token');assert.equal(headers['Idempotency-Key'],'fixture-key');assert.ok(deadline>Date.now());
});

test('Android mutation native failure never falls back to Expo or replays on another origin',async()=>{
  let probes=0,mutations=0;
  const api=client(()=>assert.fail('global Fetch'),{platform:'android',expoFetch:async()=>{probes++;return ok();},native:{apiMutationNoReplay:true,
    requestApiMutation:async()=>{mutations++;throw new Error('Network request failed');},cancelApiMutation(){},
  }});
  await assert.rejects(api.rawRequest('/v1/devices/register',{method:'POST',idempotencyKey:'fixture',body:{}}));assert.equal(probes,1);assert.equal(mutations,1);
});

test('Android mutation deadline cancels the no-replay ABI without starting a replacement',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const ids=[],cancelled=[];
  const api=client(()=>assert.fail('global Fetch'),{platform:'android',expoFetch:async()=>ok(),native:{apiMutationNoReplay:true,
    requestApiMutation:(id)=>{ids.push(id);return new Promise(()=>{});},cancelApiMutation:id=>cancelled.push(id),
  }});
  const result=assert.rejects(api.rawRequest('/v1/auth/login',{method:'POST',body:{},timeout:1000}),e=>e.code==='request_timeout');
  await settle();assert.equal(ids.length,1);t.mock.timers.tick(1000);await settle();await result;assert.deepEqual(cancelled,ids);t.mock.timers.tick(10000);await settle();assert.equal(ids.length,1);
});

for(const mode of ['broken','stalled','overall-deadline'])test(`HTTP 429 Retry-After survives ${mode} body without early retry or alias`,async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const calls=[];const api=client(async url=>{calls.push(url);return {ok:false,status:429,headers:{get:()=> '120'},text:mode==='broken'?async()=>{throw new TypeError('Network request failed');}:()=>new Promise(()=>{})};});
  const result=assert.rejects(api.rawRequest('/v1/vpn/profile',{timeout:1000,...(mode==='overall-deadline'?{retryCount:0}:{})}),e=>e.status===429&&e.retryAfterMs===120000);
  await settle();if(mode!=='broken'){t.mock.timers.tick(mode==='overall-deadline'?1000:500);await settle();}await result;
  t.mock.timers.tick(600);await settle();assert.deepEqual(calls,[primary+'/v1/vpn/profile']);t.mock.timers.tick(120000);await settle();assert.equal(calls.length,1);
});

for(const env of [
  {EXPO_PUBLIC_VEX_API_BASE_URL:'http://localhost:3011',EXPO_PUBLIC_VEX_API_ORIGIN:primary},
  {EXPO_PUBLIC_VEX_API_ORIGIN:'http://127.0.0.1:3011'},
  {EXPO_PUBLIC_VEX_API_BASE_URL:'http://[::1]:3011'},
])test(`SSE bearer stays on configured loopback: ${JSON.stringify(env)}`,()=>{
  const api=client(()=>assert.fail('HTTP API must not run'),{env});
  const expected=env.EXPO_PUBLIC_VEX_API_BASE_URL||env.EXPO_PUBLIC_VEX_API_ORIGIN;
  const source=stripTypeScriptTypes(fs.readFileSync('src/realtime/customerRealtimeTransport.ts','utf8'))
    .replace(/^import \{[\s\S]*?\} from '\.\/customerRealtimeCore';/m,'').replace(/\bexport /g,'');
  const Transport=new Function('customerRealtimeMetadata','customerRealtimeReconnectDelay','parseCustomerSSE',source+';return CustomerRealtimeTransport;')(()=>null,()=>0,()=>({events:[],remainder:''}));
  const requests=[];const request={open:(method,url)=>requests.push({method,url,headers:{}}),setRequestHeader:(name,value)=>{requests[0].headers[name]=value;},send(){},abort(){}};
  const stream=new Transport({accessToken:'fixture-token',baseUrl:api.realtimeApiBaseUrl,createRequest:()=>request,onEvent(){},onSessionRevoked(){},onStatus(){},schedule:()=>0,cancelSchedule(){}});
  stream.start();stream.stop();assert.deepEqual(requests,[{method:'GET',url:expected+'/v1/events',headers:{Accept:'text/event-stream',Authorization:'Bearer fixture-token','Cache-Control':'no-cache'}}]);
  assert.equal(api.vexApiBaseUrl,'https://vexguard.app');
  assert.equal(client(()=>{}).realtimeApiBaseUrl,'https://vexguard.app');
});

for(const method of ['GET','HEAD','OPTIONS'])test(`Android safe ${method} never uses the mutation ABI`,async()=>{
  const methods=[];const api=client(()=>assert.fail('global Fetch'),{platform:'android',expoFetch:async(_url,init)=>{methods.push(init.method);return ok();},native:{
    apiMutationNoReplay:true,requestApiMutation:()=>assert.fail('safe methods must use the ordinary transport'),cancelApiMutation(){},
  }});
  assert.equal(await api.rawRequest('/v1/auth/me',{method}),'ok');assert.equal(methods.at(-1),method);
});

test('Android production-only mutation ABI rejects local proxy before metadata, probes or native I/O',async()=>{
  for(const local of ['http://localhost:3011','http://127.0.0.1:3011','http://[::1]:3011']) {
    const api=client(()=>assert.fail('global Fetch'),{platform:'android',env:{EXPO_PUBLIC_VEX_API_BASE_URL:local},appInfo:()=>assert.fail('metadata'),expoFetch:()=>assert.fail('local credential/probe I/O'),native:{
      apiMutationNoReplay:true,requestApiMutation:()=>assert.fail('unsupported local origin'),cancelApiMutation(){},
    }});
    await assert.rejects(api.rawRequest('/v1/auth/login',{method:'POST',body:{password:'fixture'}}),e=>e.code==='native_mutation_origin_unsupported');
  }
});
