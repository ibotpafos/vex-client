const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=process.argv[2]||path.resolve(__dirname,'..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
assert.match(read('src/vpn/profile.ts'),/await runProfileRequest\(\(\) => preparedTunnel/);
assert.match(read('src/vpn/useVpnConnection.ts'),/canRefreshInBackground: useCallback\(\(\) => !vpnOperationInFlightRef.current/);
assert.match(read('src/vpn/useVpnProfileState.ts'),/shouldFetch: \(\) => backgroundRequestIsCurrent/);
assert.match(read('src/vpn/useVpnProfileState.ts'),/if \(!cancelled && profile && backgroundRequestIsCurrent/);
console.log('STALE_BACKGROUND_PROFILE_GUARDS=PASS');
