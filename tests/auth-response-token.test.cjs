const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');

function authModule(reply) {
  const exportsForTest = {};
  const calls = [];
  vm.runInNewContext(ts.transpileModule(
    fs.readFileSync(path.resolve(__dirname, '../src/api/auth.ts'), 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } },
  ).outputText, {
    exports: exportsForTest,
    require(name) {
      assert.equal(name, './client');
      return { jsonRequest: async (url, options) => { calls.push({ url, options }); return reply; } };
    },
  });
  return { ...exportsForTest, calls };
}

const user = { id: 'fixture-user', email: 'fixture@example.test', status: 'active' };
for (const token of [undefined, null, '', ' \t\n', 42, {}, []]) {
  test('authentication rejects missing, blank or non-string access token', () => {
    assert.throws(() => authModule().parseAuth({ user, session: { access_token: token } }),
      /не содержит access token/);
  });
}

test('valid legacy response remains usable and trims boundary whitespace', () => {
  const session = authModule().parseAuth({
    user, session: { access_token: '  fixture-token \n', expires_at: '2030-01-01T00:00:00Z' },
  });
  assert.equal(session.accessToken, 'fixture-token');
  assert.equal(session.user.id, user.id);
  assert.equal(session.expiresAt, '2030-01-01T00:00:00Z');
});

test('missing optional expiry does not prevent a valid session', () => {
  assert.equal(authModule().parseAuth({ user, session: { access_token: 'fixture-token' } }).expiresAt, undefined);
});

test('all public authentication flows reject an unusable successful response', async () => {
  const auth = authModule({ user, session: { access_token: ' ' } });
  for (const operation of [
    () => auth.login('fixture@example.test', 'fixture-password'),
    () => auth.confirmEmailOTP('fixture@example.test', 'fixture-challenge', '123456'),
    () => auth.exchangeGoogleIDToken('fixture-google-token'),
    () => auth.exchangeAppAuthCode('fixture-code', 'fixture-verifier'),
    () => auth.refreshSession('fixture-old-token'),
  ]) {
    await assert.rejects(operation, /не содержит access token/);
  }
  assert.equal(auth.calls.length, 5);
});
