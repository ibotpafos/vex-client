const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const profileStatePath = process.env.VEX_PROFILE_STATE_SOURCE || path.join(__dirname, '..', 'src/vpn/useVpnProfileState.ts');
const source = fs.readFileSync(profileStatePath, 'utf8');
const connectFlow = fs.readFileSync(path.join(__dirname, '..', 'src/vpn/connectFlow.ts'), 'utf8');

assert.ok(/function connectableLocalProfile[\s\S]*vpnProfileAddressMatchesDevice/.test(connectFlow), 'local profile guard must reject a profile whose tunnel address differs from its registered device');
assert.ok(/import\s*\{[^}]*connectableLocalProfile[^}]*\}\s*from ['"]\.\/connectFlow['"]/.test(source), 'profile resolution must use the existing local-profile consistency guard');
assert.ok(/const cachedLocalProfile\s*=\s*preferCached[\s\S]*?connectableLocalProfile\(/.test(source), 'cached Android profiles must be address-validated before native connect');
assert.ok(/const connectableHotProfile\s*=\s*hotProfile\?\.hotProfileUsed\s*\?\s*connectableLocalProfile\(/.test(source), 'hot Android profiles must be address-validated before native connect');
assert.ok(/let profile = !options\.forceRefresh && !forceRouteBudgetRefresh && cachedLocalProfile\s*\? cachedLocalProfile/.test(source), 'an explicit cached profile must not bypass the consistency guard during online resolution');
console.log('ANDROID_LOCAL_PROFILE_CONSISTENCY=PASS');
