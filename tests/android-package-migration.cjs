const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2] || path.resolve(__dirname, '..');
const app = JSON.parse(fs.readFileSync(path.join(root, 'app.json'))).expo;
const versions = JSON.parse(fs.readFileSync(path.join(root, 'versions.json'))).android;
const gradle = fs.readFileSync(path.join(root, 'android/app/build.gradle'), 'utf8');
const config = fs.readFileSync(path.join(root, 'app.config.ts'), 'utf8');
const versionMatch = /^(\d+)\.(\d+)\.(\d+)$/.exec(versions.version);
assert.ok(versionMatch, 'Android version must use major.minor.patch');
const expectedVersionCode =
  Number(versionMatch[1]) * 1_000_000 +
  Number(versionMatch[2]) * 10_000 +
  Number(versionMatch[3]) * 100 +
  Number(versions.build);
assert.equal(app.android.package, 'com.vexguard.app');
assert.equal(app.android.versionCode, expectedVersionCode);
assert.equal(app.version, versions.version);
assert.match(gradle, /applicationId "com\.vexguard\.app"/);
assert.match(gradle, new RegExp(`versionCode ${expectedVersionCode}`));
assert.match(config, /env\('VEX_ANDROID_APPLICATION_ID', 'com\.vexguard\.app'\)/);
assert.equal(versions.version, app.version);
assert.ok(Number.isInteger(versions.build) && versions.build > 0);
assert.equal(versions.is_required, false);
assert.equal(versions.checksum_sha256, '');
assert.equal(versions.signature_url, '');
console.log('NEW_PACKAGE_AND_UNPUBLISHED_METADATA=PASS');
