const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const root = path.resolve(__dirname, '..');
const read = name => readFileSync(path.join(root, name), 'utf8');
const manifest = JSON.parse(read('package.json'));
const lock = JSON.parse(read('package-lock.json'));

test('SDK 58 dependencies resolve to the Expo compatibility matrix', () => {
  const expected = require('../node_modules/expo/bundledNativeModules.json');
  const semver = require('semver');
  assert.match(lock.packages['node_modules/expo'].version, /^58\./);
  for (const [name, range] of Object.entries(expected)) {
    if (!manifest.dependencies[name] && !manifest.devDependencies[name]) continue;
    if (manifest.expo.install.exclude.includes(name)) continue;
    assert.ok(semver.satisfies(lock.packages[`node_modules/${name}`].version, range), name);
  }
  assert.equal(manifest.overrides['@expo/metro'], undefined);
  assert.equal(manifest.overrides['@expo/fingerprint'], undefined);
  assert.equal(manifest.resolutions['@expo/fingerprint'], undefined);
  assert.equal(manifest.devDependencies['react-compiler'], undefined);
  assert.ok(manifest.devDependencies['babel-plugin-react-compiler']);
});

test('Android release preserves native application identity without promoting iOS', () => {
  const config = JSON.parse(read('app.json')).expo;
  assert.equal(config.ios.bundleIdentifier, 'com.vexguard.app');
  assert.equal(config.android.package, 'com.vexguard.app');
  assert.equal(config.scheme, 'vexguard');
  assert.deepEqual(JSON.parse(read('versions.json')).ios.version, '1.0.48');
});

test('Android uses the SDK 58 Gradle and AGP compatibility settings', () => {
  const wrapper = read('android/gradle/wrapper/gradle-wrapper.properties');
  assert.match(wrapper, /gradle-9\.4\.1-bin\.zip/);
  assert.match(wrapper, /distributionSha256Sum=[a-f0-9]{64}/);
  assert.match(read('android/gradle.properties'), /android.builtInKotlin=false/);
  assert.match(read('android/gradle.properties'), /android.newDsl=false/);
  assert.doesNotMatch(read('android/app/build.gradle'), /proguard-android\.txt/);
  assert.doesNotMatch(read('android/app/build.gradle'), /newArchEnabled = true/);
  assert.ok(read('android/app/build.gradle').includes("assets.srcDir(layout.buildDirectory.dir('generated/xray-notices').get().asFile)"));
  assert.ok(read('android/app/build.gradle').includes("dependsOn bootstrapXrayAndroid, copyXrayNotices"));
});

test('SDK 58 candidates cannot reuse SDK 57 OTA runtime versions', () => {
  const semver = require('semver');
  const versions = JSON.parse(read('versions.json'));
  assert.ok(semver.gt(versions.android.version, '1.0.92'));
  assert.equal(manifest.version, versions.android.version);
  assert.equal(JSON.parse(read('app.json')).expo.version, versions.android.version);
  assert.ok(read('android/app/build.gradle').includes(`vexRuntimeVersion: vexBuildValue('VEX_RUNTIME_VERSION', "${versions.android.version}")`));
  const publisher = read('scripts/publish_ota_update.sh');
  assert.ok(publisher.includes('if [[ "${runtime_version}" != "${current_runtime}" ]]'));
  assert.match(publisher, /refusing to build a new/);
});
