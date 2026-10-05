const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const root = path.join(__dirname, '..');
test('About wires bounded OTA provenance without update ID', () => {
 const info=fs.readFileSync(path.join(root,'src/native/appInfo.ts'),'utf8');
 const screen=fs.readFileSync(path.join(root,'src/screens/settings-screen.tsx'),'utf8');
 assert.match(info,/getOtaProvenance/); assert.match(info,/otaRuntimeVersion/); assert.match(info,/otaLaunch/);
 assert.doesNotMatch(screen,/ota_update_id|updateId/); assert.match(screen,/Применённое обновление/);
});
