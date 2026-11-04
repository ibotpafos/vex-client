import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { runProfileRequest, ProfileRequestSupersededError } from '../src/vpn/profileRequestQueue.ts';
const root=process.argv[2]||'src/vpn';
const connection=fs.readFileSync(path.join(root,'useVpnConnection.ts'),'utf8');
const profile=fs.readFileSync(path.join(root,'useVpnProfileState.ts'),'utf8');
const callback=connection.match(/canRefreshInBackground: useCallback\((.*?), \[transport\]\)/s)[1].replace(/: string/g,'');
const predicate=profile.match(/const backgroundRequestIsCurrent = useCallback\([\s\S]*?=> \{([\s\S]*?)\}, \[transport\]\);/)[1];
const vpnOperationInFlightRef={current:true},selectedLocationIdRef={current:'de'};
const canRefreshInBackground=new Function('vpnOperationInFlightRef','selectedLocationIdRef','vpnStatusRef','normalizeVpnTransport','transport',`return (${callback});`)(vpnOperationInFlightRef,selectedLocationIdRef,{current:{state:'disconnected'}},value=>value??'amneziawg','amneziawg');
const scope={current:{transport:'amneziawg',accessToken:'fixture',selectedLocationId:'de',canRefreshInBackground}};
const guard=new Function('currentRequestScope','token','location','transport',predicate);
let backend='de-awg31-features';
// Publish the new selection synchronously, then unlock BEFORE React renders it.
selectedLocationIdRef.current='de-awg31-features';
vpnOperationInFlightRef.current=false;
const old=runProfileRequest(async()=>{backend='de';},()=>guard(scope,'fixture','de','amneziawg'));
await assert.rejects(old,ProfileRequestSupersededError);
assert.equal(backend,'de-awg31-features');
// After render, the legitimate selected background request remains available.
scope.current.selectedLocationId='de-awg31-features';
await runProfileRequest(async()=>{backend='de-awg31-features';},()=>guard(scope,'fixture','de-awg31-features','amneziawg'));
assert.match(connection,/selectedLocationIdRef.current = locationId;\s*setSelectedLocationState\(locationId\)/);
assert.doesNotMatch(connection,/selectedLocationIdRef.current = selectedLocationId/);
console.log('UNLOCK_BEFORE_RENDER_STALE_ISSUANCE_REJECTED=PASS');
