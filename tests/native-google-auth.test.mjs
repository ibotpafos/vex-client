import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildAppWebAuthUrl } from '../src/auth/webAuthUrl';

const input = { baseUrl: 'https://example.invalid/', challenge: 'fixture-challenge', deviceId: 'fixture-device', deviceName: 'Fixture & Device', platform: 'android', state: 'fixture-state' };
const ordinary = new URL(buildAppWebAuthUrl(input));
const google = new URL(buildAppWebAuthUrl({ ...input, provider: 'google' }));
assert.equal(google.searchParams.get('provider'), 'google');
assert.equal(ordinary.searchParams.has('provider'), false);
assert.equal(google.pathname, '/auth/app');
for (const [key, value] of ordinary.searchParams) assert.equal(google.searchParams.get(key), value);
assert.equal(google.searchParams.get('state'), input.state);
assert.equal(google.searchParams.get('code_challenge'), input.challenge);
const screen = readFileSync('src/screens/sign-in-screen.tsx', 'utf8');
assert.match(screen, /onPress=\{handleGoogleSignIn\}/);
assert.match(screen, /await signInWithGoogleAndroid\(\)/);
assert.match(screen, /Войти через Google/);
assert.doesNotMatch(screen, /console\.(?:log|warn|error)\([^;]*\burl\s*\)/i);
assert.doesNotMatch(screen, /mfaCode|setMfaCode|Код аутентификатора/);
assert.match(screen, /code.length !== 6/);
const api = readFileSync('src/api/auth.ts', 'utf8');
assert.doesNotMatch(api, /mfa_code|mfaCode/);
assert.match(api, /device_session: true/);
const otp = readFileSync('src/components/otp-code-input.tsx', 'utf8');
assert.match(otp, /one-time-code/);
const service = readFileSync('macos-native/Sources/VEXNativeMac/Services/PKCEAuthService.swift', 'utf8');
assert.match(service, /URLQueryItem\(name: "provider", value: provider.rawValue\)/);
assert.match(service, /ASWebAuthenticationSession/);
assert.match(service, /storedState == returnedState/);
const state = readFileSync('macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift', 'utf8');
assert.match(state, /beginWebAuth\(mode: \.login, provider: \.google\)/);
assert.match(state, /startWebAuth\(mode: mode, provider: provider\)/);
const panel = readFileSync('macos-native/Sources/VEXNativeMac/Views/SignInPanel.swift', 'utf8');
assert.match(panel, /appState.openGoogleSignIn\(\)/);
assert.match(panel, /Войти через Google/);
console.log('PASS: Google URL preserves PKCE/state; Android uses native Google; macOS retains browser handoff; client OTP has no MFA input and retains six-digit/autofill checks');

const { exchangeNativeGoogleCredential, isGoogleSignInCancelled } = await import('../src/auth/googleSignIn.ts');
let exchanges = 0;
const exchange = async token => { exchanges++; assert.equal(token, 'fixture-id-token'); return { accessToken: 'fixture-vex-session' }; };
assert.deepEqual(await exchangeNativeGoogleCredential(async () => 'fixture-id-token', exchange), { accessToken: 'fixture-vex-session' });
assert.equal(exchanges, 1);
await assert.rejects(exchangeNativeGoogleCredential(async () => '', exchange));
assert.equal(exchanges, 1);
const cancelled = { code: 'GOOGLE_SIGN_IN_CANCELLED' };
await assert.rejects(exchangeNativeGoogleCredential(async () => { throw cancelled; }, exchange), e => e === cancelled);
assert.equal(exchanges, 1);
assert.equal(isGoogleSignInCancelled(cancelled), true);
assert.equal(isGoogleSignInCancelled(new Error('network')), false);
assert.equal(isGoogleSignInCancelled(null), false);
await assert.rejects(exchangeNativeGoogleCredential(async () => 'fixture-id-token', async () => { throw new Error('invalid audience'); }), /invalid audience/);
const native = readFileSync('android/app/src/main/java/com/vexguard/app/vpn/VexGoogleAuthModule.kt', 'utf8');
assert.match(native, /GetSignInWithGoogleOption.Builder/);
assert.match(native, /compareAndSet\(false, true\)/);
assert.match(native, /finally\s*\{\s*inFlight.set\(false\)/);
assert.match(native, /clearCredentialState\(ClearCredentialStateRequest\(\)\)/);
assert.doesNotMatch(native, /https?:\/\/|Log\.|startActivity/);
assert.match(api, /'\/v1\/auth\/oauth\/google'/);
console.log('PASS: native Google credential exchange, empty token, cancellation, rejection, retry guard and sign-out contracts');

// Execute the actual UI callback with inert platform effects. Validation must
// happen before it replaces a previous PKCE attempt or opens a browser.
const ts = (await import('typescript')).default;
const { stripTypeScriptTypes } = await import('node:module');
const { validatedApiBaseUrl } = await import('../src/api/config.ts');
const tree = ts.createSourceFile('screen.tsx', screen, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let callback;
function visit(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(tree) === 'handleWebAuthStart') callback = node.initializer.arguments[0];
  ts.forEachChild(node, visit);
}
visit(tree);
assert.ok(callback, 'actual web-auth callback must be found');
for (const baseUrl of ['relative/path', 'https://user:fixture@example.invalid', 'https://example.invalid?other', 'https://example.invalid#fragment', 'http://[invalid']) {
  const effects = { nonce: 0, writes: 0, device: 0, browser: 0 };
  const inFlight = { current: false };
  let error, busy;
  const deps = {
    authSubmitInFlight: inFlight, playLightImpactHaptic: () => {}, playErrorHaptic: () => {},
    setIsAuthBusy: value => { busy = value; }, setAuthError: value => { error = value; },
    validatedApiBaseUrl: () => validatedApiBaseUrl(baseUrl), vexApiBaseUrl: baseUrl,
    generateRandomString: () => { effects.nonce++; return 'fixture'; }, generateChallenge: async () => 'fixture',
    SecureStore: { setItemAsync: async () => { effects.writes++; } },
    getOrCreateDeviceId: async () => { effects.device++; return 'fixture'; },
    getDeviceDetails: () => ({ platform: 'ios', deviceName: 'fixture' }), buildAppWebAuthUrl,
    openWebAuthUrl: async () => { effects.browser++; return ''; }, isAppAuthCallbackUrl: () => false,
    handleCallbackUrl: async () => {}, console: { log() {}, error() {} },
  };
  const handler = new Function(...Object.keys(deps), 'return (' + stripTypeScriptTypes(callback.getText(tree)) + ');')(...Object.values(deps));
  await handler('google');
  assert.equal(error, 'Неверно настроен адрес API.');
  assert.deepEqual(effects, { nonce: 0, writes: 0, device: 0, browser: 0 });
  assert.equal(inFlight.current, false);
  assert.equal(busy, false);
}
console.log('PASS: invalid API configuration cannot replace PKCE state, access device identity or open web auth');
