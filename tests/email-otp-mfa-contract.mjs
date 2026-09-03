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

await exports.confirmEmailOTP('fixture@example.com', 'fixture-challenge', '123456', '654321');
assert.equal(request.path, '/v1/auth/email-otp/confirm');
assert.equal(request.body.code, '123456');
assert.equal(request.body.challenge_id, 'fixture-challenge');
assert.equal(request.body.mfa_code, '654321', 'native email login must transmit the separate second factor');
assert.equal(request.body.device_session, true);
await exports.confirmEmailOTP('fixture@example.com', 'fixture-challenge', '123456');
assert.ok(!request.body.mfa_code, 'non-MFA login stays compatible');

const screen = readFileSync(new URL('../src/screens/sign-in-screen.tsx', import.meta.url), 'utf8');
assert.match(screen, /value=\{mfaCode\}/);
assert.match(screen, /confirmEmailOTP\([\s\S]*?emailOTPChallenge\.challengeId,[\s\S]*?code,[\s\S]*?mfaCode/);
assert.match(screen, /Код аутентификатора/);
const input = readFileSync(new URL('../src/components/otp-code-input.tsx', import.meta.url), 'utf8');
assert.equal((input.match(/<TextInput\s/g) || []).length, 1, 'email OTP retains one input');
assert.match(input, /autoComplete="one-time-code"/);
assert.match(input, /textContentType="oneTimeCode"/);
assert.match(input, /importantForAutofill="yes"/);
console.log('PASS: separate MFA payload, non-MFA compatibility, UI wiring, email autofill hints');
