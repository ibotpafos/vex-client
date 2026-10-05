const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const test = require('node:test');

const root = process.env.CLIENT_PACKAGE_JSON || path.join(__dirname, '..', 'package.json');
const ts = createRequire(root)('typescript');
const sourcePath = process.env.OTA_PROVENANCE_SOURCE || path.join(__dirname, '..', 'src', 'diagnostics', 'otaProvenance.ts');

function provenance(updates) {
  const code = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(code, {
    module, exports: module.exports,
    require: (id) => {
      assert.equal(id, 'expo-updates');
      return updates;
    },
  }, { filename: sourcePath });
  return module.exports.getOtaProvenance();
}

test('reports bounded OTA identity and launch state', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(provenance({
    updateId: '45f1420d-43a7-4c7d-9412-2e7fd4236ad4',
    runtimeVersion: '1.0.64',
    isEmbeddedLaunch: false,
    isEmergencyLaunch: false,
    emergencyLaunchReason: null,
  }))), {
    ota_update_id: '45f1420d-43a7-4c7d-9412-2e7fd4236ad4',
    ota_runtime_version: '1.0.64',
    ota_is_embedded_launch: false,
    ota_is_emergency_launch: false,
  });
});

test('accepts canonical hex-shaped native update ids regardless of UUID version and variant bits', () => {
  const nativeShapedId = '01ab23cd-4567-0abc-cdef-0123456789ab';
  const result = provenance({
    updateId: nativeShapedId,
    runtimeVersion: '1.0.66',
    isEmbeddedLaunch: false,
    isEmergencyLaunch: false,
    emergencyLaunchReason: null,
  });
  assert.equal(result.ota_update_id, nativeShapedId);
});

test('rejects malformed, absent, and overlong update ids while retaining launch states', () => {
  const cases = [null, 'not-a-canonical-id', 'a'.repeat(37)];
  for (const updateId of cases) {
    const result = provenance({
      updateId,
      runtimeVersion: null,
      isEmbeddedLaunch: true,
      isEmergencyLaunch: true,
      emergencyLaunchReason: null,
    });
    assert.equal(result.ota_update_id, undefined);
    assert.equal(result.ota_is_embedded_launch, true);
    assert.equal(result.ota_is_emergency_launch, true);
  }
});

test('omits non-release runtime values and never exports raw emergency errors', () => {
  const rawReason = 'signature verification failed for customer@example.test token=secret';
  const result = provenance({
    updateId: 'not-a-uuid',
    runtimeVersion: 'customer@example.test',
    isEmbeddedLaunch: true,
    isEmergencyLaunch: true,
    emergencyLaunchReason: rawReason,
  });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    ota_is_embedded_launch: true,
    ota_is_emergency_launch: true,
  });
  assert.equal(JSON.stringify(result).includes(rawReason), false);
});

test('caps a syntactically numeric runtime version at 96 characters', () => {
  const result = provenance({
    updateId: null,
    runtimeVersion: `${'1'.repeat(95)}.0.0`,
    isEmbeddedLaunch: false,
    isEmergencyLaunch: false,
    emergencyLaunchReason: null,
  });
  assert.equal(result.ota_runtime_version, undefined);
});
