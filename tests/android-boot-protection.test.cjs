const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.VEX_BOOT_SOURCE_ROOT || path.join(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const manifest = read('android/app/src/main/AndroidManifest.xml');
// Android resolves an implicit package intent and rejects the whole package if
// any advertised VPN service opts out. The transport must remain explicit.
const services = [...manifest.matchAll(/<service\b([^>]+)>([\s\S]*?)<\/service>/g)];
const advertised = services.filter(([, , body]) => body.includes('android.net.VpnService"'));
assert.equal(advertised.length, 1, 'Exactly one system Always-on entry point');
const [all, attributes, body] = advertised[0];
assert.match(attributes, /android:name="\.vpn.VexBootProtectionService"/);
assert.match(attributes, /android:directBootAware="true"/);
assert.match(attributes, /android:process=":boot_protection"/);
assert.match(attributes, /android:permission="android.permission.BIND_VPN_SERVICE"/);
assert.match(body, /SUPPORTS_ALWAYS_ON" android:value="true"/);
assert.doesNotMatch(all, /SUPPORTS_ALWAYS_ON" android:value="false"/);
for (const name of ['org.amnezia.awg.backend.GoBackend$VpnService', '.vpn.VexLeakBlockerService']) {
  const service = services.find(([, attrs]) => attrs.includes(`android:name="${name}"`));
  assert.ok(service);
  assert.match(service[2], /<intent-filter tools:node="removeAll"\/>/);
}
const boot = read('android/app/src/main/java/com/vexguard/app/vpn/VexBootProtectionService.kt');
assert.match(boot, /class VexBootProtectionService : VexLeakBlockerService\(\)/);
assert.match(boot, /super.onStartCommand\(null, flags, startId\)/);
assert.doesNotMatch(boot, /getSharedPreferences|filesDir|WireGuardKeyStore|fetch\(|https:/);
const app = read('android/app/src/main/java/com/vexguard/app/MainApplication.kt');
assert.ok(app.indexOf('if (isBootProtectionProcess(this)) return') < app.indexOf('loadReactNative(this)'));
console.log('ANDROID_BOOT_PROTECTION_CONTRACT=PASS (merged APK and physical boot require separate verification)');
