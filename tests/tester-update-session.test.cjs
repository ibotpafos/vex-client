const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require('typescript');

function load(file, dependencies) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  vm.runInNewContext(code, { exports, Error, require(name) {
    assert.ok(Object.hasOwn(dependencies, name), `unexpected import ${name}`);
    return dependencies[name];
  } });
  return exports;
}

test('update API sends enrollment identity as a header option, never in JSON', async () => {
  const requests = [];
  const api = load('src/api/updates.ts', {
    '@/native/appInfo': { VEX_API_CLIENT_VERSION: 'fixture-api', VEX_CONFIG_SCHEMA_VERSION: 1 },
    './updatePreflight': { normalizeUpdateCheckVersion: x => x },
    './client': { jsonRequest: async (url, options) => { requests.push({ url, options }); return { channel: 'beta' }; }, absolutizeUrl: x => x },
  });
  const input = { accessToken: 'fixture-token-only', platform: 'android', appVersion: '1.2.3', buildNumber: 123 };
  await api.appUpdateCheck(input); await api.appRemoteConfig(input);
  assert.equal(requests[0].options.headers['X-Vex-Account-Updates'], '1');
  for (const { options } of requests) {
    assert.equal(options.headers['X-Vex-Account-Updates'], '1');
    assert.equal(options.accessToken, input.accessToken);
    assert.equal(Object.hasOwn(options.body, 'accessToken'), false);
    assert.equal(JSON.stringify(options.body).includes(input.accessToken), false);
  }
  await api.appUpdateCheck({ platform: 'android', appVersion: '1.2.3', buildNumber: 123 });
  assert.equal(requests[2].options.accessToken, undefined, 'anonymous stable checks stay supported');
});

const apiErrors = load('src/api/error.ts', {});
const cancellation = load('src/api/requestCancellation.ts', { './error': apiErrors });

function queryFixture({ sessionRevision = 1, loading = false, current = () => true, info = async () => ({ version: '1.2.3', channel: 'stable' }), update = async () => ({ updateAvailable: true }) } = {}) {
  const session = { accessToken: `fixture-token-${sessionRevision}`, user: { id: 'fixture-account' } };
  const hook = load('src/components/mobile-app-update-query.ts', {
    '@tanstack/react-query': { useQuery: options => options },
    'react-native': { Platform: { Version: 'fixture-os' } },
    'react': { useMemo: fn => fn(), useCallback: fn => fn },
    '@/api/updatePreflight': { updateCheckChannel: x => x, shouldOfferAppUpdate: () => true },
    '@/api/vexApi': { appUpdateCheck: update },
    '@/api/error': apiErrors, '@/api/requestCancellation': cancellation,
    '@/api/queryRetry': { createApiQueryRetry: () => false },
    '@/native/appInfo': { getAppInfo: info, getOrCreateDeviceId: async () => 'fixture-device' },
    '@/auth/session-context': { useSession: () => ({ session, sessionRevision, isLoading: loading, isCurrentSessionOperation: current }) },
  });
  return hook.useMobileAppUpdateQuery('android', 123);
}
test('update cache belongs to a login boundary without storing its bearer token', () => {
  const a = queryFixture({ sessionRevision: 1 }), b = queryFixture({ sessionRevision: 2 });
  assert.notDeepEqual(a.queryKey, b.queryKey);
  assert.doesNotMatch(JSON.stringify(a.queryKey), /fixture-token/);
  assert.equal(queryFixture({ loading: true }).enabled, false);
  assert.equal(queryFixture({ current: () => false }).enabled, false);
});
test('logout during app-info lookup cannot start a former-account update request', async () => {
  let finish, current = true, requests = 0;
  const info = new Promise(resolve => { finish = resolve; });
  const q = queryFixture({ current: () => current, info: () => info, update: async () => { requests++; } });
  const pending = q.queryFn(); current = false; finish({ version: '1.2.3', channel: 'stable' });
  await assert.rejects(pending, /session changed/); assert.equal(requests, 0);
});
test('late beta response cannot publish after its login has ended', async () => {
  let finish, reached, current = true;
  const started = new Promise(resolve => { reached = resolve; });
  const wire = new Promise(resolve => { finish = resolve; });
  const q = queryFixture({ current: () => current, update: input => { assert.equal(input.accessToken, 'fixture-token-1'); reached(); return wire; } });
  const pending = q.queryFn(); await started; current = false; finish({ channel: 'beta', updateAvailable: true });
  await assert.rejects(pending, /session changed/);
});
