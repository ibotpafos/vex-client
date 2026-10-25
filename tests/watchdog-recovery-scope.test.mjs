import fs from 'node:fs';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';
import {recoverVpnConnection} from '../src/vpn/connectionRecovery.ts';
import {SessionOperationSupersededError} from '../src/vpn/sessionOperation.ts';

const source=stripTypeScriptTypes(fs.readFileSync(process.env.VEX_WATCHDOG_SOURCE || 'src/vpn/useNativeVpnWatchdog.ts','utf8'))
  .replace(/import[\s\S]*?from '[^']+';/g,'').replace('export function useNativeVpnWatchdog','function useNativeVpnWatchdog');
const tick=()=>new Promise(r=>setImmediate(r));
const profile=locationId=>({locationId,device:{id:'fixture'},config:locationId});
const parentSource=stripTypeScriptTypes(fs.readFileSync('src/vpn/useVpnConnection.ts','utf8'));
const protectionCallback=parentSource.match(/const protectFailedNativeWatchdogRecovery = useCallback\(([\s\S]*?), \[antiLeakEnabled\]\)/)?.[1];
assert.ok(protectionCallback, 'Use the actual parent recovery teardown callback');

for(const stage of ['catalog','callbacks','profile','background','new-intent','new-account','new-location','failed-target','persist-rejected','anti-leak-off']) {
  test(`a native failover cannot lose its owner during ${stage}`,async()=>{
    let cursor=0,deps,cleanup,interval,generation=0,accountCurrent=true,release;
    const slots=[],ui=[],persist=[],cache=[],telemetry=[],operation={current:false};
    const nativeGate=new Promise(r=>release=r);
    let nativeLocation='nl';
    const equal=(a,b)=>a&&b&&a.length===b.length&&a.every((v,i)=>Object.is(v,b[i]));
    const stubs={useRef:v=>{const i=cursor++;return slots[i]??(slots[i]={current:v});},
      useCallback:(fn,ds)=>{const i=cursor++;if(!slots[i]||!equal(slots[i].deps,ds))slots[i]={value:fn,deps:ds};return slots[i].value;},
      useEffect:(fn,ds)=>{if(!equal(deps,ds)){cleanup?.();deps=ds;cleanup=fn();}},
      setInterval:fn=>{interval=fn;return 0;},clearInterval:()=>{},Platform:{OS:'android'},errorMessage:String,
      SessionOperationSupersededError,recoverVpnConnection,
      dynamicRouteRuntime:{recordActiveFailure:()=>null},routeTransport:()=>'',vpnTransportTelemetry:()=>({}),
      assessNativeTunnelHealth:()=>({healthy:false,reasons:['stale']}),assessVpnAutopilotIssue:()=>({sample:{}}),
      initialRecoveryBackoffState:()=>({}),recoveryAttemptAllowed:()=>true,resetRecoveryBackoff:()=>({}),recordRecoveryFailure:()=>({})};
    const hook=new Function(...Object.keys(stubs),source+';return useNativeVpnWatchdog;')(...Object.values(stubs));
    const input={enabled:true,sessionAccessToken:'fixture',activeDeviceId:'fixture',activeLocationId:'nl',activeProfile:profile('nl'),
      availableLocations:['nl','de'].map(id=>({id,availability:'available',status:'healthy',healthyNodes:1,latencyMs:1})),
      operationInFlightRef:operation,isVpnBusy:false,isCurrentLocation:id=>id==='nl',isCurrentSessionOperation:()=>accountCurrent,
      beginRecoveryOperation:()=>{const own=++generation;return ()=>own===generation&&accountCurrent;},
      fetchDeviceUsage:async()=>[],failureThreshold:1,reconnectCooldownMs:0,probeHealth:async()=>({}),
      connectProfile:async(p,isCurrent=()=>true)=>{
        if(p.locationId==='nl')throw new Error('transport unavailable');
        assert.ok(isCurrent());nativeLocation='de';await nativeGate;
        if(!isCurrent())throw new SessionOperationSupersededError();
        if(stage==='failed-target'||stage==='anti-leak-off')throw new Error('unverified native exit');
        return {profile:p,status:{state:'connected'}};
      },
      resolveProfile:async(id,options)=>{if(options.isCurrentOperation)assert.ok(options.isCurrentOperation());return profile(id);},
      isRetryableConnectError:()=>true,persistLocation:async id=>{if(stage==='persist-rejected')throw new Error('preference unavailable');persist.push(id);return id;},setCachedProfile:id=>cache.push(id),
      protectFailedRecovery:new Function('disconnectVpn','antiLeakEnabled','return ('+protectionCallback+');')(
        async ({releaseAntiLeak})=>{nativeLocation=releaseAntiLeak?'direct':'blocked';},stage!=='anti-leak-off'),
      onRecoverySucceeded:(p,s,id)=>ui.push(id),onRecoveryFailed:()=>ui.push('failed'),reportConnect:()=>{},
      submitDiagnostics:async(reason,status,samples)=>telemetry.push({reason,status,samples})};
    const render=value=>{cursor=0;hook(value);};render(input);
    for(let i=0;i<30&&nativeLocation!=='de';i++)await tick();
    assert.equal(nativeLocation,'de');assert.equal(operation.current,true);
    if(stage==='catalog')render({...input,availableLocations:[...input.availableLocations]});
    if(stage==='callbacks')render({...input,resolveProfile:(...args)=>input.resolveProfile(...args),setCachedProfile:(...args)=>input.setCachedProfile(...args)});
    if(stage==='profile')render({...input,activeProfile:{...input.activeProfile}});
    if(stage==='background')render({...input,enabled:false});
    if(stage==='new-intent'){generation++;render({...input,isVpnBusy:true});}
    if(stage==='new-account'){accountCurrent=false;generation++;render({...input,sessionAccessToken:'other-account'});}
    if(stage==='new-location')render({...input,activeLocationId:'fi'});
    release();for(let i=0;i<12;i++)await tick();
    const superseded=stage.startsWith('new-');
    const failed=stage==='failed-target'||stage==='persist-rejected'||stage==='anti-leak-off';
    assert.deepEqual(ui,superseded?[]:failed?['failed']:['de'],'accepted native exit and displayed location must commit together');
    assert.deepEqual(persist,superseded||failed?[]:['de']);assert.deepEqual(cache,superseded||failed?[]:['de']);
    if(failed)assert.equal(nativeLocation,stage==='anti-leak-off'?'direct':'blocked','stop the unaccepted native exit and respect the anti-leak preference');
    if(stage==='new-location')assert.equal(nativeLocation,'blocked');
    assert.equal(operation.current,superseded&&stage!=='new-location','an old completion must not release a newer operation lease');
    if(!superseded&&!failed)assert.equal(telemetry.filter(x=>x.reason==='native_watchdog_reconnect_result'&&x.status==='ok').length,1);
    cleanup?.();
  });
}
