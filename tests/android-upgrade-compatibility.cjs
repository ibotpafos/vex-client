const assert = require('node:assert/strict');
const { analyzeUpgrade, parseBadging, parseSigners } = require('../scripts/verify_android_upgrade.cjs');
const base = { packageName: 'com.vexguard.app', versionCode: 1005662, minSdk: 24, abis: ['arm64-v8a'], signers: ['a'.repeat(64)] };
const next = { ...base, versionCode: 1005663 };
assert.deepEqual(analyzeUpgrade(base, next), []);
assert.ok(analyzeUpgrade(base, { ...next, packageName: 'com.vexguard.client' }).includes('PACKAGE_CHANGED'));
assert.ok(analyzeUpgrade(base, { ...next, signers: ['b'.repeat(64)] }).includes('SIGNER_CHANGED'));
assert.ok(analyzeUpgrade(base, base).includes('BUILD_NOT_INCREASED'));
assert.ok(analyzeUpgrade(base, { ...next, versionCode: 1 }).includes('BUILD_NOT_INCREASED'));
assert.ok(analyzeUpgrade({ ...base, abis: ['armeabi-v7a', 'arm64-v8a'] }, next).includes('ABI_REMOVED'));
assert.ok(analyzeUpgrade(base, { ...next, minSdk: 26 }).includes('MIN_SDK_RAISED'));
assert.deepEqual(analyzeUpgrade(base, { ...next, abis: ['arm64-v8a', 'armeabi-v7a'] }), []);
for (const patch of [{ signers: [] }, { signers: ['invalid'] }, { abis: [] }, { minSdk: NaN }, { versionCode: 0 }, { packageName: '' }]) {
  assert.throws(() => analyzeUpgrade(base, { ...next, ...patch }));
}
assert.deepEqual(parseBadging("package: name='com.vexguard.app' versionCode='1005663' versionName='1.0.56'\nsdkVersion:'24'\nnative-code: 'arm64-v8a' 'armeabi-v7a'"), {
  packageName: 'com.vexguard.app', versionCode: 1005663, minSdk: 24, abis: ['arm64-v8a', 'armeabi-v7a'],
});
assert.throws(() => parseBadging(''));
assert.deepEqual(parseSigners('Signer #1 certificate SHA-256 digest: ' + 'A'.repeat(64)), ['a'.repeat(64)]);
assert.throws(() => parseSigners('WARNING: not signed'));
// execFileSync error.message includes stderr: it must never reach release logs.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vex-upgrade-test-'));
try {
  const apk = path.join(dir, 'fixture.apk');
  fs.writeFileSync(apk, 'fixture');
  // Node receives aapt's first argument "dump" as the script; no OS shell needed.
  fs.writeFileSync(path.join(dir, 'dump'), "process.stderr.write('FIXTURE_STDERR_MARKER'); process.exit(3);\n");
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../scripts/verify_android_upgrade.cjs'), apk, apk], {
    cwd: dir, env: { ...process.env, AAPT_BIN: process.execPath, APKSIGNER_BIN: process.execPath }, encoding: 'utf8',
  });
  assert.equal(result.status, 2);
  assert.doesNotMatch(result.stderr + result.stdout, /FIXTURE_STDERR_MARKER/);
  assert.match(result.stderr, /TOOL_FAILED status=3/);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
console.log('ANDROID_UPGRADE_COMPATIBILITY=PASS');
