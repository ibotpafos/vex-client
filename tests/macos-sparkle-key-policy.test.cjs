const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Buffer } = require('node:buffer');

const root = path.resolve(__dirname, '..');
const stableKey = fs.readFileSync(path.join(root, 'macos-native/sparkle-public-ed-key.txt'), 'utf8').trim();
const otherKey = Buffer.alloc(32, 23).toString('base64');

function buildConfiguration(overrides = {}, localKey, localProduction) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vex-sparkle-key-policy-'));
  try {
    fs.mkdirSync(path.join(directory, 'scripts'));
    fs.mkdirSync(path.join(directory, 'macos-native'));
    fs.copyFileSync(path.join(root, 'scripts/build_native_macos_app.sh'), path.join(directory, 'scripts/build_native_macos_app.sh'));
    fs.writeFileSync(path.join(directory, 'macos-native/sparkle-public-ed-key.txt'), stableKey + '\n');
    // Stop at the first build boundary. No compiler, signing tool, application,
    // helper socket or host network command is executed by this fixture.
    fs.writeFileSync(path.join(directory, 'scripts/build_swift_macos_helper.sh'),
      '#!/bin/bash\nprintf ready > "$VEX_TEST_MARKER"\nexit 73\n', { mode: 0o755 });
    if (localKey) fs.writeFileSync(path.join(directory, '.env.sparkle.local'),
      `VEX_SPARKLE_PUBLIC_ED_KEY='${localKey}'\n${localProduction === undefined ? '' : `VEX_NATIVE_PRODUCTION=${localProduction}\n`}`);
    const marker = path.join(directory, 'build-boundary');
    const result = spawnSync('/bin/bash', [path.join(directory, 'scripts/build_native_macos_app.sh')], {
      encoding: 'utf8', timeout: 15000,
      env: { PATH: process.env.PATH, TMPDIR: directory, VEX_NATIVE_PRODUCTION: '1',
        VEX_CODESIGN_IDENTITY: 'inert-fixture', VEX_TEST_MARKER: marker, ...overrides },
    });
    return { status: result.status, output: result.stdout + result.stderr, reachedBuild: fs.existsSync(marker) };
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}

test('production uses the reviewed stable key by default and accepts its explicit CI pin', () => {
  for (const overrides of [{}, { VEX_SPARKLE_PUBLIC_ED_KEY: stableKey }]) {
    const result = buildConfiguration(overrides);
    assert.equal(result.status, 73, result.output);
    assert.equal(result.reachedBuild, true);
  }
});

test('a different CI or legacy local key cannot reach production build or signing', () => {
  for (const [overrides, localKey, localProduction] of [[{ VEX_SPARKLE_PUBLIC_ED_KEY: otherKey }, undefined],
    [{ VEX_SPARKLE_PUBLIC_ED_KEY: stableKey }, otherKey], [{ VEX_SPARKLE_PUBLIC_ED_KEY: stableKey }, otherKey, '0']]) {
    const result = buildConfiguration(overrides, localKey, localProduction);
    assert.equal(result.status, 2, result.output);
    assert.match(result.output, /differs from the reviewed stable key/);
    assert.equal(result.reachedBuild, false);
  }
});

test('custom development keys remain available without claiming stable update compatibility', () => {
  const result = buildConfiguration({ VEX_NATIVE_PRODUCTION: '0', VEX_SPARKLE_PUBLIC_ED_KEY: otherKey });
  assert.equal(result.status, 73, result.output);
  assert.equal(result.reachedBuild, true);
});
