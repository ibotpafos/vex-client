const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const root = resolve(__dirname, '..');
const gradle = readFileSync(resolve(root, 'android/app/build.gradle'), 'utf8');
const application = readFileSync(resolve(root, 'android/app/src/main/java/com/vexguard/app/MainApplication.kt'), 'utf8');
const app = JSON.parse(readFileSync(resolve(root, 'app.json'), 'utf8'));
const version = app.expo.version;
const build = app.expo.android.versionCode;
const packageName = app.expo.android.package;

assert.match(gradle, new RegExp(`applicationId "${packageName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`));
assert.match(gradle, new RegExp(`versionCode ${build}`));
assert.match(gradle, new RegExp(`versionName "${version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`));
assert.match(gradle, /def vexNativeSentryRelease = "vex-android@\$\{versionName\}\+\$\{versionCode\}"/);
assert.match(gradle, /SENTRY_RELEASE", buildConfigString\(vexBuildValue\('EXPO_PUBLIC_SENTRY_RELEASE', vexNativeSentryRelease\)\)/);
assert.doesNotMatch(gradle, /SENTRY_RELEASE"[\s\S]{0,160}VEX_RUNTIME_VERSION/);
assert.match(application, /options\.release = BuildConfig\.SENTRY_RELEASE\.ifBlank/);
assert.match(application, /options\.dist = BuildConfig\.VERSION_CODE\.toString\(\)/);
for (const field of ['APPLICATION_ID', 'VERSION_NAME', 'VERSION_CODE', 'SENTRY_RELEASE']) assert.match(application, new RegExp(`BuildConfig\\.${field}`));

console.log('ANDROID_NATIVE_SENTRY_RELEASE_CONTRACT=PASS canonical-native-release-derived-from-version-sync-literals-not-ota-runtime');
