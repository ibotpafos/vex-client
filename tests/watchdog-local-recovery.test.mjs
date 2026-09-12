import fs from 'node:fs';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';
const source=stripTypeScriptTypes(fs.readFileSync('src/vpn/useNativeVpnWatchdog.ts','utf8')).replace(/import[\s\S]*?from '[^']+';/g,'').replace('export function useNativeVpnWatchdog','function useNativeVpnWatchdog');
test('confirmed local failure recovers without waiting for backend usage or a network probe',async()=>{
 let effect,usage=0,probes=0,recovered=0;
 const stubs={useCallback:f=>f,useRef:value=>({current:value}),useEffect:f=>effect=f,setInterval:()=>0,clearInterval:()=>{},errorMessage:String,
 localStatusHealthReasons:()=>['local_status_error'],vpnUnexpectedDisconnectTelemetry:()=>null,vpnTransportTelemetry:()=>({}),
 assessNativeTunnelHealth:()=>({healthy:false,reasons:['local_status_error']}),assessVpnAutopilotIssue:()=>({sample:{}}),
 initialRecoveryBackoffState:()=>({}),recoveryAttemptAllowed:()=>true,resetRecoveryBackoff:()=>({}),recordRecoveryFailure:()=>({}),
 recoverVpnConnection:async()=>{recovered++;return {ok:true,profile:{},status:{state:'connected'},locationId:'de'};}};
 const run=new Function(...Object.keys(stubs),source+';return useNativeVpnWatchdog;')(...Object.values(stubs));
 const watchdog=run({enabled:true,activeDeviceId:'device',activeLocationId:'de',activeProfile:{locationId:'de',device:{id:'device'}},sessionAccessToken:'fixture',operationInFlightRef:{current:false},failureThreshold:1,reconnectCooldownMs:0,
 fetchDeviceUsage:()=>{usage++;return new Promise(()=>{});},probeHealth:()=>{probes++;return new Promise(()=>{});},submitDiagnostics:async()=>{},reportConnect:()=>{},onRecoverySucceeded:()=>{}});
 watchdog.recordNativeStatus({state:'connected'},{state:'error'});
 const cleanup=effect();
 for(let i=0;i<40;i++)await Promise.resolve();
 assert.equal(usage,0);assert.equal(probes,0);assert.equal(recovered,1);cleanup();
});
