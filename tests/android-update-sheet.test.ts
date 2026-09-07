/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { AppUpdateCheckResult } from '../src/api/types';
import { shouldShowUpdateSheet, type AndroidDownloadState } from '../src/updates/androidUpdateSheet';

const update: AppUpdateCheckResult = {
  updateAvailable: true,
  delivery: 'native',
  required: false,
  currentBuildBlocked: false,
  latestVersion: '1.0.57',
  latestBuild: 1005765,
  minSupportedBuild: 1002930,
  downloadUrl: 'https://vexguard.app/downloads/Vex-Android-1.0.57.apk',
  reason: 'update_available',
};

for (const state of [
  { status: 'ready', build: 1005765 },
  { status: 'installing', build: 1005765 },
  { status: 'permission_required', build: 1005765 },
  { status: 'error', build: 1005765, message: 'Network request failed' },
] satisfies AndroidDownloadState[]) {
  test(`optional native update keeps ${state.status} feedback visible`, () => {
    assert.equal(shouldShowUpdateSheet(update, state, null, null, { ok: true }), true);
  });
}

test('optional update stays dismissed when the user chooses later', () => {
  assert.equal(shouldShowUpdateSheet(update, { status: 'ready', build: 1005765 }, 1005765, null, { ok: true }), false);
});

test('successful installer handoff closes the sheet even for required updates', () => {
  assert.equal(shouldShowUpdateSheet({ ...update, required: true }, { status: 'installer_opened', build: 1005765 }, null, 1005765, { ok: true }), false);
});

test('required update with invalid metadata remains visible for error feedback', () => {
  assert.equal(shouldShowUpdateSheet({ ...update, required: true }, { status: 'idle' }, null, null, { ok: false }), true);
});

test('OTA updates do not open the APK installer sheet', () => {
  assert.equal(shouldShowUpdateSheet({ ...update, delivery: 'ota' }, { status: 'ready', build: 1005765 }, null, null, { ok: true }), false);
});

test('idle optional check does not open a sheet', () => {
  assert.equal(shouldShowUpdateSheet(update, { status: 'idle' }, null, null, { ok: true }), false);
});
