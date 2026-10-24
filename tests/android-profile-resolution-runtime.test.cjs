const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const test = require('node:test');
const repo = path.resolve(__dirname, '..');
const sourcePath = process.env.VEX_PROFILE_STATE_SOURCE || path.join(repo, 'src/vpn/useVpnProfileState.ts');
let clock = () => Date.now();
class FixtureClock extends Date { static now() { return clock(); } }
function load(file, deps) {
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: name => {
    assert.ok(Object.hasOwn(deps, name), `unexpected import ${name}`); return deps[name];
  }, Error, Date: FixtureClock, Promise, setTimeout, clearTimeout, console });
  return exports;
}
const consistency = load(path.join(repo, 'src/vpn/profileConsistency.ts'), {});
const fallback = load(path.join(repo, 'src/vpn/connectionFallback.ts'), {});
const entitlementAccess = load(path.join(repo, 'src/api/entitlement.ts'), {});
const profileCore = load(path.join(repo, 'src/vpn/hotProfileCacheCore.ts'), { './locationId': load(path.join(repo, 'src/vpn/locationId.ts'), {}) });
const connectFlow = load(path.join(repo, 'src/vpn/connectFlow.ts'), { '../api/entitlement': entitlementAccess, './profileConsistency': consistency, './connectionFallback': fallback, './hotProfileCacheCore': profileCore });
const androidSafety = load(path.join(repo, 'src/vpn/androidRoutingSafety.ts'), {});
const paid = { active: true, vpnAccess: true };
const inactive = { active: false, vpnAccess: false };
function profile(address, assigned = address, source = 'api') {
  return { config: `[Interface]\nAddress = ${address}/32\n[Peer]\nPublicKey = fixture`, device: { id: 'device', assignedIpv4: assigned }, entitlement: paid, locationId: 'de', routingMode: 'default', source };
}
async function resolveCase({ cached, hot, knownEntitlement = paid, permission = true, permissionWait, keyAdmissionWait, explicit, expectedError, expectedSource, expectOnline }) {
  let online = 0; let subscription = 0; let permissionCalls = 0;
  const publishedProfiles = [];
  const fresh = profile('10.0.0.9');
  const queryClient = {
    getQueryData: () => cached ?? null,
    setQueryData: (key, value) => { if (key[0] === 'vpn-profile') { cached = value; publishedProfiles.push(value); } }, removeQueries: () => {},
    fetchQuery: async ({ queryFn }) => queryFn(), invalidateQueries: async () => {},
  };
  const react = { useCallback: fn => fn, useEffect: () => {}, useMemo: fn => fn(), useRef: value => ({ current: value }), useState: value => [value, () => {}] };
  const module = load(sourcePath, {
    react, '../hooks/useOwnedState': load(path.join(repo, 'src/hooks/useOwnedState.ts'), { react }),
    '@tanstack/react-query': { useQueryClient: () => queryClient, isCancelledError: () => false },
    '../api/error': load(path.join(repo, 'src/api/error.ts'), {}),
    'react-native': { Platform: { OS: 'android' } },
    '@/utils/error': { errorMessage: e => e instanceof Error ? e.message : String(e) },
    '../api/vexApi': { vpnProfileKeyIsCurrent: async () => { await keyAdmissionWait?.(); return true; }, entitlement: async () => knownEntitlement, hasPaidEntitlement: entitlementAccess.hasPaidEntitlement },
    './profile': { resetVpnProfileCache: () => {}, resolveVpnProfile: async () => { online++; return fresh; }, rotateVpnProfileKey: async () => fresh },
    './profileRequestQueue': { ProfileRequestSupersededError: class ProfileRequestSupersededError extends Error {} },
    './sessionOperation': { SessionOperationSupersededError: class SessionOperationSupersededError extends Error {} },
    './serverSwitch': {},
    './hotProfileCache': { clearHotVpnProfiles: async () => {}, hydrateHotVpnProfilesToQueryCache: async () => [], loadHotVpnProfileResult: async () => ({ record: hot ?? null }), profileFromHotRecord: record => ({ ...record, hotProfileUsed: true, source: 'local' }), saveHotVpnProfile: async () => {} },
    './connectFlow': connectFlow,
    './routingPolicy': {}, './androidRoutingSafety': androidSafety,
  });
  const state = module.useVpnProfileState({ accessToken: 'token', hasVpnAccess: true, knownEntitlement, onDeviceRevoked: async () => {}, onProfileRotationRequired: () => {}, onSubscriptionRequired: () => { subscription++; }, profileRefreshMs: 1, requestVpnPermission: async () => { permissionCalls++; await permissionWait?.(); return permission; }, routingMode: 'default', selectedLocationId: 'de', userId: hot ? 'user' : undefined });
  let result; let error;
  try { result = await state.resolveConnectableVpnProfile('de', explicit ? { cachedProfile: explicit } : {}); } catch (caught) { error = caught; }
  if (expectedError) {
    assert.match(error?.message ?? '', expectedError);
  } else {
    assert.equal(error, undefined);
    assert.equal(result.source, expectedSource);
  }
  assert.equal(online, expectOnline);
  return { permissionCalls, subscription, result, cached, publishedProfiles };
}
(async () => {
  await resolveCase({ cached: profile('10.0.0.2', '10.0.0.3', 'local'), expectedSource: 'api', expectOnline: 1 });
  await resolveCase({ cached: profile('10.0.0.2', '10.0.0.2', 'local'), expectedSource: 'local', expectOnline: 1 });
  await resolveCase({ explicit: profile('10.0.0.2', '10.0.0.3', 'local'), expectedSource: 'api', expectOnline: 1 });
  await resolveCase({ hot: profile('10.0.0.2', '10.0.0.3', 'local'), cached: null, expectedSource: 'api', expectOnline: 1 });
  const denied = await resolveCase({ cached: null, knownEntitlement: inactive, expectedError: /Подписка не активна/, expectOnline: 0 });
  assert.equal(denied.subscription, 1);
  const permissionDenied = await resolveCase({ cached: null, permission: false, expectedError: /Разрешение Android VPN не выдано/, expectOnline: 0 });
  assert.equal(permissionDenied.permissionCalls, 1);
  for (const source of ['query', 'hot']) {
    await test(`${source} profile expiring during permission wait is replaced before publication`, async () => {
      let now = 1000 + profileCore.hotVpnProfileTtlMs; clock = () => now;
      const old = { ...profile('10.0.0.2'), cacheSavedAtMs: 1000 };
      const resolved = await resolveCase({ [source === 'query' ? 'cached' : 'hot']: old,
        permissionWait: () => { now++; }, expectedSource: 'api', expectOnline: 1 });
      assert.equal(resolved.permissionCalls, 1, 'expiry must not prompt for permission twice');
      assert.equal(resolved.result.config, profile('10.0.0.9').config, 'the expired selected profile must be replaced online');
    });
  }
  for (const source of ['query', 'hot']) await test(source + ' profile expiring during key admission is replaced before publication', async () => {
    let now = 1000 + profileCore.hotVpnProfileTtlMs; clock = () => now;
    const old = { ...profile('10.0.0.2'), cacheSavedAtMs: 1000 };
    const resolved = await resolveCase({ [source === 'query' ? 'cached' : 'hot']: old,
      keyAdmissionWait: () => { now++; }, expectedSource: 'api', expectOnline: 1 });
    assert.equal(resolved.permissionCalls, 1);
    assert.equal(resolved.result.config, profile('10.0.0.9').config);
  });
  await test('the owning hook replaces a legacy query copy with its anchored local receipt', async () => {
    clock = () => 1000;
    const legacy = await resolveCase({ cached: profile('10.0.0.2'), expectedSource: 'local', expectOnline: 1 });
    assert.equal(legacy.result.cacheSavedAtMs, 1000);
    assert.equal(legacy.publishedProfiles[0].cacheSavedAtMs, 1000, 'legacy query copy must be replaced with its anchored local copy');
  });
  clock = () => Date.now();
  console.log('ANDROID_PROFILE_RESOLUTION_RUNTIME=PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
