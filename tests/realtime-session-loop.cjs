const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('typescript');
const path = require('node:path');
let options, refreshes=0, invalidations=0;
const modules={
 'react':{createContext:()=>({Provider:()=>null}),use:()=>null,useEffect:f=>f(),useMemo:f=>f(),useState:v=>[v,()=>{}]},
 'react/jsx-runtime':{jsx:()=>null},
 'react-native':{AppState:{currentState:'active',addEventListener:()=>({remove(){}})}},
 '@tanstack/react-query':{useQueryClient:()=>({invalidateQueries:()=>{invalidations++;return Promise.resolve();}})},
 '@/api/vexApi':{vexApiBaseUrl:'https://fixture.invalid'},
 '@/auth/session-context':{useSession:()=>({session:{accessToken:'fixture-token'},refreshSession:()=>{refreshes++;return Promise.resolve();},signOut:()=>Promise.resolve()})},
 './customerRealtimeTransport':{CustomerRealtimeTransport:class {constructor(o){options=o;}start(){}stop(){}}},
};
function load(file){const module={exports:{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX}}).outputText,{module,exports:module.exports,require:id=>{if(id==='./customerRealtimeCore')return load(path.resolve(__dirname,'../src/realtime/customerRealtimeCore.ts'));if(modules[id])return modules[id];throw Error(id);},Set,JSON});return module.exports;}
load(process.argv[2]||path.resolve(__dirname,'../src/realtime/customer-realtime-context.tsx')).CustomerRealtimeProvider({children:null});
for(let i=0;i<20;i++) options.onEvent({type:'customer.resync',data:JSON.stringify({versions:[],reason:'initial'})});
console.log(`resync_refreshes=${refreshes} invalidations=${invalidations}`);
assert.equal(refreshes,0,'resync must not rotate and revoke the token used by device registration');
assert.ok(invalidations>0,'resync must still refresh account data queries');
options.onEvent({type:'customer.change',data:JSON.stringify({domain:'account',version:21})});
assert.equal(refreshes,0,'data changes are not token expiration');
options.onSessionRevoked();assert.equal(refreshes,1,'explicit auth recovery remains active');
console.log('PASS: stable token during resync/account updates; explicit auth recovery retained');
