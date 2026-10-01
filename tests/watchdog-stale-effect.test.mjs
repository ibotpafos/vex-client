import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
const file=process.argv[2]||'src/vpn/useNativeVpnWatchdog.ts';
const source=stripTypeScriptTypes(fs.readFileSync(file,'utf8')).replace(/import[\s\S]*?from '[^']+';/g,'').replace('export function useNativeVpnWatchdog','function useNativeVpnWatchdog');
const tick=()=>new Promise(r=>setTimeout(r,0));
for(const stage of ['usage','probe','diagnostics','render-lag','other-operation','success','phase-render']){
 let cleanup,interval,release,render;let cursor=0,effectDeps;const slots=[];const pending=new Promise(r=>release=r);const events=[];let current=true,fetches=0;
 const operation={current:false};
 const depsEqual=(a,b)=>a&&b&&a.length===b.length&&a.every((v,i)=>Object.is(v,b[i]));
 const stubs={useCallback:(f,deps)=>{const i=cursor++;if(!slots[i]||!depsEqual(slots[i].deps,deps))slots[i]={value:f,deps};return slots[i].value;},
 useRef:v=>{const i=cursor++;return slots[i]??(slots[i]={current:v});},
 useEffect:(f,deps)=>{if(!depsEqual(effectDeps,deps)){cleanup?.();effectDeps=deps;cleanup=f();}},errorMessage:e=>String(e),
 assessNativeTunnelHealth:()=>({healthy:false,reasons:['stale']}),assessVpnAutopilotIssue:()=>({sample:{}}),
 initialRecoveryBackoffState:()=>({}),recoveryAttemptAllowed:()=>true,recordRecoveryFailure:()=>({}),resetRecoveryBackoff:()=>({}),vpnTransportTelemetry:()=>({}),
 recoverVpnConnection:async input=>{assert.equal(operation.current,true,'recovery must own shared operation');events.push('recover');await input.connectProfile(input.activeProfile);return {ok:true,profile:input.activeProfile,status:{state:'connected'},locationId:input.activeLocationId};},
 setInterval:f=>{interval=f;return 0;},clearInterval:()=>{}};
 const run=new Function(...Object.keys(stubs),source+';return useNativeVpnWatchdog;')(...Object.values(stubs));
 const input={enabled:true,sessionAccessToken:'fixture',activeDeviceId:'device',activeLocationId:'de31',activeProfile:{locationId:'de31'},operationInFlightRef:operation,isCurrentLocation:()=>current,
 fetchDeviceUsage:async()=>{fetches++;if(stage==='usage'||stage==='render-lag'||stage==='other-operation')await pending;return [];},failureThreshold:1,reconnectCooldownMs:0,
 probeHealth:async()=>{if(stage==='probe')await pending;return {};},submitDiagnostics:async reason=>{if(reason==='native_watchdog_reconnect'&&(stage==='diagnostics'||stage==='success'||stage==='phase-render'))await pending;},
 connectProfile:async()=>events.push('native'),onRecoverySucceeded:()=>events.push('UI'),reportConnect:()=>{},
 onRecoveryStarted:()=>{if(stage==='phase-render')queueMicrotask(()=>render({...input,submitDiagnostics:async(...args)=>input.submitDiagnostics(...args),reportConnect:()=>{}}));}};
 render=value=>{cursor=0;run(value);};render(input);
 await tick();
 if(stage==='usage'){interval();await tick();assert.equal(fetches,1,'health checks must not overlap');}
 if(stage==='diagnostics'||stage==='success'||stage==='phase-render')assert.equal(operation.current,true,'shared lease acquired before awaited diagnostics');
 if(stage==='render-lag')current=false;else if(stage==='other-operation')operation.current=true;else if(stage!=='success'&&stage!=='phase-render')cleanup();
 release();await tick();await tick();
 assert.deepEqual(events,(stage==='success'||stage==='phase-render')?['recover','native','UI']:[],stage+' must not activate a disposed/stale profile');
 assert.equal(operation.current,stage==='other-operation','only owner releases operation lease');
 operation.current=false;
 cleanup();
}
console.log('WATCHDOG_ASYNC_CANCELLATION_AND_SHARED_LEASE=PASS');
