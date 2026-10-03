const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const test = require('node:test');

const root = process.env.CLIENT_PACKAGE_JSON || path.join(__dirname, '..', 'package.json');
const ts = createRequire(root)('typescript');
const sourcePath = process.env.SENTRY_SOURCE || path.join(__dirname, '..', 'src', 'observability', 'sentry.ts');

function initialized(options = {}) {
  const calls = [];
  const code = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(code, {
    module, exports: module.exports,
    process: { env: { EXPO_PUBLIC_SENTRY_DSN: 'https://public@example.invalid/1', ...options.env } },
    require: (id) => ({
      '@sentry/react-native': { init: (input) => calls.push(input), captureException: () => undefined },
      'expo-application': { nativeApplicationVersion: options.version ?? '1.0.64', nativeBuildVersion: options.build ?? '1006472' },
      'react-native': { Platform: { OS: 'android' } },
    })[id],
  }, { filename: sourcePath });
  module.exports.initSentry();
  return calls;
}

test('Sentry release, dist, and tags identify the native binary without customer metadata', () => {
  const [input] = initialized();
  assert.equal(input.release, 'vex-android@1.0.64+1006472');
  assert.equal(input.dist, '1006472');
  assert.deepEqual(JSON.parse(JSON.stringify(input.initialScope.tags)), {
    app_platform: 'android', native_app_version: '1.0.64', native_build_version: '1006472',
  });
  assert.equal(JSON.stringify(input).includes('device'), false);
  assert.equal(JSON.stringify(input).includes('customer'), false);
});

test('explicit release remains authoritative', () => {
  const [input] = initialized({ env: { EXPO_PUBLIC_SENTRY_RELEASE: 'vex@approved-release' } });
  assert.equal(input.release, 'vex@approved-release');
});
