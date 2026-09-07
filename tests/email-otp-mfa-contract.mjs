import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/api/auth.ts', import.meta.url), 'utf8');
let request;
const exports = {};
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText, {
  exports,
  require: (name) => {
    assert.equal(name, './client');
    return { jsonRequest: async (path, options) => {
      request = { path, ...options };
      return { user: { id: 'fixture-user', email: 'fixture@example.com' }, session: {} };
    } };
  },
});

// The native client requests a limited device session, never an account-security session.
for (const unexpectedMfa of [undefined, '654321']) {
  await exports.confirmEmailOTP('fixture@example.com', 'fixture-challenge', '123456', unexpectedMfa);
  assert.equal(request.path, '/v1/auth/email-otp/confirm');
  assert.equal(request.method, 'POST');
  assert.deepEqual(JSON.parse(JSON.stringify(request.body)), {
    email: 'fixture@example.com',
    challenge_id: 'fixture-challenge',
    code: '123456',
    remember_me: true,
    device_session: true,
  });
  assert.equal(Object.hasOwn(request.body, 'mfa_code'), false, 'unexpected fourth argument never becomes an MFA payload');
}

const screen = readFileSync(new URL('../src/screens/sign-in-screen.tsx', import.meta.url), 'utf8');
assert.doesNotMatch(screen, /mfaCode|setMfaCode|Код аутентификатора/);
assert.match(screen, /confirmEmailOTP\(\s*normalizedEmail,\s*emailOTPChallenge\.challengeId,\s*code,?\s*\)/);
assert.match(screen, /code.length !== 6/);
assert.match(screen, /handleWebAuthStart\("google"\)/, 'Google uses the separate browser handoff');
assert.match(screen, /buildAppWebAuthUrl\(/);
assert.match(screen, /openWebAuthUrl\(webAuthUrl\)/);
const input = readFileSync(new URL('../src/components/otp-code-input.tsx', import.meta.url), 'utf8');
assert.equal((input.match(/<TextInput\s/g) || []).length, 1, 'email OTP retains one input');
assert.match(input, /autoComplete=\{Platform.OS === 'android' \? 'email-otp' : 'one-time-code'\}/);
assert.match(input, /textContentType="oneTimeCode"/);
assert.match(input, /importantForAutofill="yes"/);
console.log('PASS: client-only email OTP payload, ignored extra MFA argument, separate Google browser flow, six-digit validation and autofill hints');
