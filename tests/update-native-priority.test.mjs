import assert from 'node:assert/strict';
import test from 'node:test';
import { canUseOtaUpdate, requiresNativeUpdate } from '../src/api/updatePreflight.ts';

const ota = { updateAvailable: true, delivery: 'ota', required: false };
test('revoked builds and native compatibility recovery outrank an OTA hint', () => {
  for (const update of [
    { ...ota, currentBuildBlocked: true },
    ...['blocked_release', 'android_signing_key_migration', 'unsupported_config_schema', 'core_version_unsupported', 'api_client_version_unsupported'].map(reason => ({ ...ota, reason })),
  ]) {
    assert.equal(requiresNativeUpdate(update), true);
    assert.equal(canUseOtaUpdate(update), false);
  }
});
test('normal explicitly compatible OTA remains available; missing update is not fabricated', () => {
  for (const update of [ota, { ...ota, required: true }, { ...ota, reason: 'update_available' }]) {
    assert.equal(requiresNativeUpdate(update), false);
    assert.equal(canUseOtaUpdate(update), true);
  }
  assert.equal(requiresNativeUpdate({ ...ota, updateAvailable: false, currentBuildBlocked: true }), false);
  assert.equal(canUseOtaUpdate(null), false);
});
