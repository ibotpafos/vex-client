const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('typescript');
const path = require('node:path');
const test = require('node:test');
let options, refreshes=0, invalidations=0;
const modules={
 'react':{createContext:()=>({Provider:()=>null}),use:()=>null,useEffect:f=>f(),useMemo:f=>f(),useState:v=>[v,()=>{}]},
 'react/jsx-runtime':{jsx:()=>null},
 'react-native':{AppState:{currentState:'active',addEventListener:()=>({remove(){}})}},
 '@tanstack/react-query':{useQueryClient:()=>({invalidateQueries:()=>{invalidations++;return Promise.resolve();}})},
 '@/api/vexApi':{vexApiBaseUrl:'https://fixture.invalid'},
 '@/auth/session-context':{useSession:()=>({session:{accessToken:'fixture-token'},isCurrentSessionOperation:()=>true,refreshSession:()=>{refreshes++;return Promise.resolve();},signOut:()=>Promise.resolve()})},
 './customerRealtimeTransport':{CustomerRealtimeTransport:class {constructor(o){options=o;}start(){}stop(){}}},
};
function load(file){const module={exports:{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX}}).outputText,{module,exports:module.exports,require:id=>{if(id==='./customerRealtimeCore')return load(path.resolve(__dirname,'../src/realtime/customerRealtimeCore.ts'));if(modules[id])return modules[id];throw Error(id);},Set,JSON});return module.exports;}
modules['@/api/error'] = load(path.resolve(__dirname, '../src/api/error.ts'));
load(process.argv[2]||path.resolve(__dirname,'../src/realtime/customer-realtime-context.tsx')).CustomerRealtimeProvider({children:null});
for(let i=0;i<20;i++) options.onEvent({type:'customer.resync',data:JSON.stringify({versions:[],reason:'initial'})});
console.log(`resync_refreshes=${refreshes} invalidations=${invalidations}`);
assert.equal(refreshes,0,'resync must not rotate and revoke the token used by device registration');
assert.ok(invalidations>0,'resync must still refresh account data queries');
options.onEvent({type:'customer.change',data:JSON.stringify({domain:'account',version:21})});
assert.equal(refreshes,0,'data changes are not token expiration');
options.onSessionRevoked();assert.equal(refreshes,1,'explicit auth recovery remains active');
console.log('PASS: stable token during resync/account updates; explicit auth recovery retained');

function recoveryHarness(refresh) {
 const cleanups = [];
 const state = { current: true, refreshes: 0, signOuts: 0 };
 modules.react.useEffect = callback => { const cleanup = callback(); if (cleanup) cleanups.push(cleanup); };
 modules['@/auth/session-context'].useSession = () => ({
  session: { accessToken: 'account-A-token' },
  isCurrentSessionOperation: () => state.current,
  refreshSession: () => { state.refreshes++; return refresh(); },
  signOut: async () => { state.signOuts++; },
 });
 load(path.resolve(__dirname, '../src/realtime/customer-realtime-context.tsx')).CustomerRealtimeProvider({ children: null });
 return { state, revoked: options.onSessionRevoked, unmount: () => cleanups.forEach(cleanup => cleanup()) };
}
const settleRecovery = () => new Promise(resolve => setImmediate(resolve));
const { ApiRequestError } = modules['@/api/error'];

test('old realtime refresh failure cannot log out the newly signed-in account', async () => {
 let reject;
 const h = recoveryHarness(() => new Promise((_, fail) => { reject = fail; }));
 h.revoked(); assert.equal(h.state.refreshes, 1);
 h.state.current = false;
 reject(new ApiRequestError('old session revoked', { status: 401 }));
 await settleRecovery();
 assert.equal(h.state.signOuts, 0, 'old account recovery must not mutate the next login');
});

test('queued realtime revocation after unmount cannot start credential recovery', async () => {
 const h = recoveryHarness(async () => undefined);
 h.unmount(); h.revoked(); await settleRecovery();
 assert.equal(h.state.refreshes, 0, 'retired provider callbacks must be inert');
});

test('temporary refresh backend failure preserves the current account', async () => {
 const h = recoveryHarness(async () => { throw new ApiRequestError('temporary backend failure', { status: 503 }); });
 h.revoked(); await settleRecovery();
 assert.equal(h.state.refreshes, 1);
 assert.equal(h.state.signOuts, 0, 'temporary failure does not establish revoked credentials');
});

test('definitively rejected refresh still signs out the current account', async () => {
 const h = recoveryHarness(async () => { throw new ApiRequestError('session revoked', { status: 401 }); });
 h.revoked(); await settleRecovery();
 assert.equal(h.state.refreshes, 1); assert.equal(h.state.signOuts, 1);
});
