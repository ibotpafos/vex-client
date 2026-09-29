import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sourcePath = process.argv[2] ?? new URL('../src/screens/home-screen-helpers.ts', import.meta.url);
const source = readFileSync(sourcePath, 'utf8');
const declaration = source.match(/export function areVpnStatusesEqual\([^)]*\)\s*\{[\s\S]*?\n\}/)?.[0];
assert.ok(declaration, 'VPN status equality function must exist');
const executable = declaration.replace(/^export function areVpnStatusesEqual\([^)]*\)/, 'function areVpnStatusesEqual(left, right)');
const areVpnStatusesEqual = new Function(`${executable}; return areVpnStatusesEqual;`)();

const connected = {
  state: 'connected',
  rxBytes: 0,
  txBytes: 0,
  latestHandshakeEpochMillis: 1_000,
  leakProtection: 'off',
  verified: false,
  verificationReason: undefined,
};
assert.equal(areVpnStatusesEqual(connected, { ...connected }), true);
for (const [field, value] of [
  ['state', 'disconnected'],
  ['rxBytes', 1],
  ['txBytes', 1],
  ['latestHandshakeEpochMillis', 2_000],
  ['leakProtection', 'on'],
  ['verified', true],
  ['verificationReason', 'probe_failed'],
]) {
  assert.equal(areVpnStatusesEqual(connected, { ...connected, [field]: value }), false, `${field} change must update VPN status`);
}
console.log('VPN_STATUS_ALL_FIELDS_CHANGE_DETECTED=PASS');
