const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const repo = path.resolve(__dirname, '..');
const sourcePath = process.env.VEX_PROFILE_STATE_SOURCE || path.join(repo, 'src/vpn/useVpnProfileState.ts');
function load(file, deps) {
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: name => {
    assert.ok(Object.hasOwn(deps, name), `unexpected import ${name}`); return deps[name];
  }, Error, Date, Promise, setTimeout, clearTimeout, console });
  return exports;
}
const consistency = load(path.join(repo, 'src/vpn/profileConsistency.ts'), {});
const fallback = load(path.join(repo, 'src/vpn/connectionFallback.ts'), {});
const connectFlow = load(path.join(repo, 'src/vpn/connectFlow.ts'), { './profileConsistency': consistency, './connectionFallback': fallback });
const androidSafety = load(path.join(repo, 'src/vpn/androidRoutingSafety.ts'), {});
const paid = { active: true, vpnAccess: true };
const inactive = { active: false, vpnAccess: false };
function profile(address, assigned = address, source = 'api') {
  return { config: `[Interface]\nAddress = ${address}/32\n[Peer]\nPublicKey = fixture`, device: { id: 'device', assignedIpv4: assigned }, entitlement: paid, locationId: 'de', routingMode: 'default', source };
}
async function resolveCase({ cached, hot, knownEntitlement = paid, permission = true, explicit, expectedError, expectedSource, expectOnline }) {
  let online = 0; let subscription = 0; let permissionCalls = 0;
  const fresh = profile('10.0.0.9');
  const queryClient = {
    getQueryData: () => cached ?? null,
    setQueryData: () => {}, removeQueries: () => {},
    fetchQuery: async ({ queryFn }) => queryFn(), invalidateQueries: async () => {},
  };
  const module = load(sourcePath, {
    react: { useCallback: fn => fn, useEffect: () => {}, useMemo: fn => fn(), useRef: value => ({ current: value }), useState: value => [value, () => {}] },
    '@tanstack/react-query': { useQueryClient: () => queryClient },
    'react-native': { Platform: { OS: 'android' } },
    '@/utils/error': { errorMessage: e => e instanceof Error ? e.message : String(e) },
    '../api/vexApi': { entitlement: async () => knownEntitlement, hasPaidEntitlement: value => Boolean(value?.active || value?.vpnAccess) },
    './profile': { resetVpnProfileCache: () => {}, resolveVpnProfile: async () => { online++; return fresh; }, rotateVpnProfileKey: async () => fresh },
    './profileRequestQueue': { ProfileRequestSupersededError: class ProfileRequestSupersededError extends Error {} },
    './sessionOperation': { SessionOperationSupersededError: class SessionOperationSupersededError extends Error {} },
    './serverSwitch': {},
    './hotProfileCache': { clearHotVpnProfiles: async () => {}, hydrateHotVpnProfilesToQueryCache: async () => [], loadHotVpnProfileResult: async () => ({ record: hot ?? null }), profileFromHotRecord: record => ({ ...record, hotProfileUsed: true, source: 'local' }), saveHotVpnProfile: async () => {} },
    './connectFlow': connectFlow,
    './routingPolicy': {}, './androidRoutingSafety': androidSafety,
  });
  const state = module.useVpnProfileState({ accessToken: 'token', hasVpnAccess: true, knownEntitlement, onDeviceRevoked: async () => {}, onProfileRotationRequired: () => {}, onSubscriptionRequired: () => { subscription++; }, profileRefreshMs: 1, requestVpnPermission: async () => { permissionCalls++; return permission; }, routingMode: 'default', selectedLocationId: 'de', userId: hot ? 'user' : undefined });
  let result; let error;
  try { result = await state.resolveConnectableVpnProfile('de', explicit ? { cachedProfile: explicit } : {}); } catch (caught) { error = caught; }
  if (expectedError) {
    assert.match(error?.message ?? '', expectedError);
  } else {
    assert.equal(error, undefined);
    assert.equal(result.source, expectedSource);
  }
  assert.equal(online, expectOnline);
  return { permissionCalls, subscription };
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
  console.log('ANDROID_PROFILE_RESOLUTION_RUNTIME=PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
