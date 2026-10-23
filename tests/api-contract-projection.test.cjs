const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const ts = require('typescript');

const root = path.resolve(__dirname, '..');
const dto = path.join(root, 'src/api/dto.ts');
const contract = path.join(root, 'src/api/generated-contract.ts');
const options = { strict: true, skipLibCheck: true, types: [], noEmit: true };
const canonicalPath = filename => {
  const normalized = path.resolve(filename).replaceAll('\\', '/');
  return ts.sys.useCaseSensitiveFileNames ? normalized : normalized.toLowerCase();
};

function diagnosticsWith({ spec, consumer } = {}) {
  const host = ts.createCompilerHost(options);
  const original = host.getSourceFile.bind(host);
  const consumerPath = path.join(root, 'src/api/projection-consumer.fixture.ts');
  host.getSourceFile = (filename, version, onError, fresh) => {
    if (canonicalPath(filename) === canonicalPath(contract) && spec !== undefined) return ts.createSourceFile(filename, spec, version, true);
    if (canonicalPath(filename) === canonicalPath(consumerPath)) return ts.createSourceFile(filename, consumer, version, true);
    return original(filename, version, onError, fresh);
  };
  const program = ts.createProgram([dto, contract, ...(consumer ? [consumerPath] : [])], options, host);
  return ts.getPreEmitDiagnostics(program);
}

function messages(diagnostics) {
  return diagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n');
}

test('native DTO projections retain legacy partial responses and reject invalid field values', () => {
  const diagnostics = diagnosticsWith({ consumer: `
    import type { AuthResultDTO, DeviceDTO, DeviceIdentityChallengeDTO, NativeVPNProfileDTO, PortalSessionDTO } from './dto';
    const device: DeviceDTO = { id: 'fixture' };
    const auth: AuthResultDTO = { user: { id: 'fixture', email: 'fixture@example.test' }, session: { expires_at: null }, access_grant: { active: true } };
    const identity: DeviceIdentityChallengeDTO = { id: 'fixture', nonce: 'nonce', purpose: 'register', expires_at: null };
    const profile: NativeVPNProfileDTO = { version: 1, revoked: false, rotation_required: false, amnezia: null, authorization: null };
    const portal: PortalSessionDTO = {};
    // @ts-expect-error the existing public device contract still requires id
    const missing: DeviceDTO = {};
    // @ts-expect-error a Go-derived numeric counter cannot become a string
    const invalid: DeviceDTO = { id: 'fixture', psk_epoch: 'wrong' };
    void [device, auth, identity, profile, portal, missing, invalid];
  ` });
  assert.equal(diagnostics.length, 0, messages(diagnostics));
});

test('native device request projections check live payload fields and compatible defaults', () => {
  const diagnostics = diagnosticsWith({ consumer: `
    import type { NativeDeviceRegistrationRequest, NativeDeviceIdentityChallengeRequest } from './dto';
    const legacy: NativeDeviceRegistrationRequest = { public_key: 'fixture', name: null, key_epoch: null, future_hint: true };
    const signed: NativeDeviceRegistrationRequest = { public_key: 'fixture', installation_id: 'fixture', identity_public_key: 'fixture', identity_key_type: 'ecdsa_p256_jwk', identity_challenge_id: 'fixture', identity_signature: 'fixture', key_epoch: 2 };
    const defaultPurpose: NativeDeviceIdentityChallengeRequest = { installation_id: 'fixture' };
    const normalizedPurpose: NativeDeviceIdentityChallengeRequest = { installation_id: 'fixture', purpose: 'future-purpose' };
    const nullPurpose: NativeDeviceIdentityChallengeRequest = { installation_id: 'fixture', purpose: null };
    // @ts-expect-error the native handler requires a public key
    const missingKey: NativeDeviceRegistrationRequest = {};
    // @ts-expect-error a required key cannot be null
    const nullKey: NativeDeviceRegistrationRequest = { public_key: null };
    // @ts-expect-error Go decodes key_epoch as an integer, not a string
    const wrongEpoch: NativeDeviceRegistrationRequest = { public_key: 'fixture', key_epoch: '1' };
    // @ts-expect-error challenge requires an installation id
    const missingInstallation: NativeDeviceIdentityChallengeRequest = {};
    // @ts-expect-error a required installation id cannot be null
    const nullInstallation: NativeDeviceIdentityChallengeRequest = { installation_id: null };
    void [legacy, signed, defaultPurpose, normalizedPurpose, nullPurpose, missingKey, nullKey, wrongEpoch, missingInstallation, nullInstallation];
  ` });
  assert.equal(diagnostics.length, 0, messages(diagnostics));
});

test('native lifecycle inputs retain root/default compatibility and required key/ACK fields', () => {
  const diagnostics = diagnosticsWith({ consumer: `
    import type { NativeVPNKeyRotationInput, NativeVPNConnectionEventInput, NativeVPNPushTokenInput, NativeVPNPSKRotationACKInput } from './dto';
    const rotation: NativeVPNKeyRotationInput = {public_key:'fixture', key_epoch:null, future_hint:true};
    const event: NativeVPNConnectionEventInput = {profile_version:null, client_time:null, future_hint:true};
    const nullEvent: NativeVPNConnectionEventInput = null;
    const emptyEvent: NativeVPNConnectionEventInput = {};
    const push: NativeVPNPushTokenInput = {provider:'future-provider',token:null};
    const nullPush: NativeVPNPushTokenInput = null;
    const emptyPush: NativeVPNPushTokenInput = {};
    const ack: NativeVPNPSKRotationACKInput = {profile_version:2,profile_digest:'fixture',device_id:null};
    // @ts-expect-error rotation requires a nonnull public key
    const missingKey: NativeVPNKeyRotationInput = {};
    // @ts-expect-error rotation key is a string
    const badKey: NativeVPNKeyRotationInput = {public_key:null};
    // @ts-expect-error epochs decode as integers, not strings
    const badEpoch: NativeVPNKeyRotationInput = {public_key:'fixture',key_epoch:'1'};
    // @ts-expect-error event version cannot be a string
    const badEvent: NativeVPNConnectionEventInput = {profile_version:'2'};
    // @ts-expect-error push token cannot be an array
    const badPush: NativeVPNPushTokenInput = {token:[]};
    // @ts-expect-error ACK requires the exact profile version
    const missingVersion: NativeVPNPSKRotationACKInput = {profile_digest:'fixture'};
    // @ts-expect-error ACK digest cannot be null
    const missingDigest: NativeVPNPSKRotationACKInput = {profile_version:2,profile_digest:null};
    void [rotation,event,nullEvent,emptyEvent,push,nullPush,emptyPush,ack,missingKey,badKey,badEpoch,badEvent,badPush,missingVersion,missingDigest];
  ` });
  assert.equal(diagnostics.length, 0, messages(diagnostics));
});

test('removing an optional Go field still invalidates a native projection', () => {
  const fs = require('node:fs');
  const source = ts.createSourceFile(contract, fs.readFileSync(contract, 'utf8'), ts.ScriptTarget.Latest, true);
  let removed = 0;
  const result = ts.transform(source, [context => rootNode => ts.visitNode(rootNode, function visit(node) {
    if (ts.isInterfaceDeclaration(node) && node.name.text === 'DeviceDTOSpec') {
      const members = node.members.filter(member => {
        const keep = member.name?.getText(source) !== 'protocol_label';
        if (!keep) removed += 1;
        return keep;
      });
      return ts.factory.updateInterfaceDeclaration(node, node.modifiers, node.name, node.typeParameters, node.heritageClauses, members);
    }
    return ts.visitEachChild(node, visit, context);
  })]);
  try {
    assert.equal(removed, 1, 'the production optional field must exist for this mutation');
    const spec = ts.createPrinter().printFile(result.transformed[0]);
    const diagnostics = diagnosticsWith({ spec });
    assert.ok(diagnostics.some(item => item.code === 2344 && ts.flattenDiagnosticMessageText(item.messageText, '\n').includes('protocol_label')), messages(diagnostics));
  } finally {
    result.dispose();
  }
});
