import assert from 'node:assert/strict';
import test from 'node:test';
import {assessNativeTunnelHealth} from '../src/vpn/nativeTunnelHealth.ts';
const input={deviceUsage:{connected:false,connectionStatus:'stale',secondsSinceHandshake:600},nowMs:1_000_000,staleHandshakeSeconds:180};
test('fresh local handshake overrides delayed server usage counters',()=>{
 assert.deepEqual(assessNativeTunnelHealth({...input,status:{state:'connected',latestHandshakeEpochMillis:999_000}}),{healthy:true,reasons:[]});
});
test('missing or stale local handshake does not hide backend evidence',()=>{
 for(const timestamp of [undefined,0,500_000,1_001_000])assert.equal(assessNativeTunnelHealth({...input,status:{state:'connected',latestHandshakeEpochMillis:timestamp}}).healthy,false);
});
test('fresh handshake must not hide leak blocking or disconnection',()=>{
 for(const status of [{state:'connected',leakProtection:'blocking'},{state:'disconnected'},{state:'error'}])assert.equal(assessNativeTunnelHealth({...input,status:{...status,latestHandshakeEpochMillis:999_000}}).healthy,false);
});
