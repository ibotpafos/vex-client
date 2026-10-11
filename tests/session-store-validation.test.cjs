const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');
const React = require('react');
const { renderToStaticMarkup } = require('react-dom/server');

const file = path.resolve(__dirname, '../src/auth/sessionStoreCore.ts');
const exportsForTest = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsForTest });
const { parseStoredSession, loadSessionFromStorage, sessionKey, sessionHistoryKey } = exportsForTest;
const valid = { accessToken: 'fixture-token', user: { id: 'fixture-user', email: 'fixture@example.test' } };

function storage(primary, history) {
  const values = new Map([[sessionKey, primary], [sessionHistoryKey, history]]);
  const removed = [];
  return {
    values, removed,
    getItemAsync: async key => values.get(key) ?? null,
    setItemAsync: async (key, value) => { values.set(key, value); },
    deleteItemAsync: async key => { removed.push(key); values.delete(key); },
  };
}

test('legacy valid sessions without optional fields remain readable', () => {
  assert.equal(JSON.stringify(parseStoredSession(JSON.stringify(valid))), JSON.stringify(valid));
  const withExpiry = { ...valid, expiresAt: '2030-01-01T00:00:00Z', user: { ...valid.user, status: 'active' } };
  assert.equal(JSON.stringify(parseStoredSession(JSON.stringify(withExpiry))), JSON.stringify(withExpiry));
});

const malformed = [
  ['object token', { ...valid, accessToken: { value: 'fixture-token' } }],
  ['numeric token', { ...valid, accessToken: 42 }],
  ['blank token', { ...valid, accessToken: ' ' }],
  ['missing owner', { ...valid, user: { email: valid.user.email } }],
  ['object owner', { ...valid, user: { ...valid.user, id: { value: valid.user.id } } }],
  ['numeric owner', { ...valid, user: { ...valid.user, id: 42 } }],
  ['blank owner', { ...valid, user: { ...valid.user, id: ' ' } }],
  ['object email', { ...valid, user: { ...valid.user, email: { value: valid.user.email } } }],
  ['array email', { ...valid, user: { ...valid.user, email: [valid.user.email] } }],
  ['numeric email', { ...valid, user: { ...valid.user, email: 42 } }],
  ['blank email', { ...valid, user: { ...valid.user, email: ' ' } }],
];
for (const [name, value] of malformed) {
  test(`reject malformed persisted ${name} before exposing an authenticated session`, () => {
    assert.equal(parseStoredSession(JSON.stringify(value)), null);
  });
}

test('offline restoration cannot publish an object-valued email to React account text', async () => {
  const s = storage(JSON.stringify({ ...valid, user: { ...valid.user, email: { value: valid.user.email } } }), null);
  const restored = await loadSessionFromStorage(s);
  assert.doesNotThrow(() => renderToStaticMarkup(React.createElement('span', null, restored?.user.email ?? '')));
  assert.equal(restored, null);
  assert.deepEqual(s.removed, [sessionKey]);
});

test('malformed primary falls back to valid legacy history and repairs primary', async () => {
  const s = storage(JSON.stringify({ ...valid, user: { ...valid.user, id: 42 } }), JSON.stringify(valid));
  const restored = await loadSessionFromStorage(s);
  assert.equal(JSON.stringify(restored), JSON.stringify(valid));
  assert.equal(s.values.get(sessionKey), JSON.stringify(valid));
  assert.deepEqual(s.removed, [sessionKey]);
});

test('malformed primary and history cannot restore an ownerless session', async () => {
  const s = storage(JSON.stringify({ ...valid, user: { email: valid.user.email } }),
    JSON.stringify({ ...valid, user: { ...valid.user, id: {} } }));
  assert.equal(await loadSessionFromStorage(s), null);
  assert.deepEqual(s.removed, [sessionKey, sessionHistoryKey]);
});
