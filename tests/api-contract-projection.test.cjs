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
