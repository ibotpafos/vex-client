import assert from 'node:assert/strict';
import test from 'node:test';

const { updateCheckChannel, normalizeUpdateCheckVersion } = await import('../src/api/updatePreflight.ts');
const { default: appConfig } = await import('../app.config.ts');

test('metadata update channel maps QA preview to the supported stable contract', () => {
  const cases = [
    ['preview', 'stable'],
    [' PREVIEW ', 'stable'],
    ['production', 'stable'],
    ['local', 'stable'],
    ['test', 'stable'],
    ['stable', 'stable'],
    [' beta ', 'beta'],
    ['custom-channel', 'custom-channel'],
    ['', 'stable'],
  ];
  for (const [input, expected] of cases) assert.equal(updateCheckChannel(input), expected, input);
});

test('metadata update version strips only the generated diagnostic QA suffix', () => {
  assert.equal(normalizeUpdateCheckVersion('1.0.67.diagnosticfixqa.dev'), '1.0.67');
  assert.equal(normalizeUpdateCheckVersion('1.0.67'), '1.0.67');
  assert.equal(normalizeUpdateCheckVersion('1.0.67-dev'), '1.0.67-dev');
  assert.equal(normalizeUpdateCheckVersion('1.0.67.other.dev'), '1.0.67.other.dev');
  assert.equal(normalizeUpdateCheckVersion('not-a-version.diagnosticfixqa.dev'), 'not-a-version.diagnosticfixqa.dev');
});

test('Expo OTA preview header remains preview and is not metadata-normalized', () => {
  const names = ['EXPO_PUBLIC_VEX_UPDATE_CHANNEL', 'VEX_BUILD_PROFILE', 'VEX_UPDATES_ENABLED', 'VEX_EAS_PROJECT_ID', 'VEX_RUNTIME_VERSION'];
  const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  try {
    process.env.EXPO_PUBLIC_VEX_UPDATE_CHANNEL = 'preview';
    process.env.VEX_BUILD_PROFILE = 'preview';
    process.env.VEX_UPDATES_ENABLED = '1';
    process.env.VEX_EAS_PROJECT_ID = 'fixture-project-id';
    process.env.VEX_RUNTIME_VERSION = '1.0.67';
    const config = appConfig({ config: {} });
    assert.equal(config.extra?.vex?.updateChannel, 'preview');
    assert.equal(config.updates?.requestHeaders?.['expo-channel-name'], 'preview');
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
