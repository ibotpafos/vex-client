const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const modulePath = process.env.VEX_IOS_BRIDGE_MODULE_SOURCE || path.join(root, 'modules/vex-vpn/ios/VexVpnModule.swift');
const moduleSource = fs.readFileSync(modulePath, 'utf8');
const sharedSource = fs.readFileSync(path.join(root, 'src/native/vexVpn.ts'), 'utf8');
const expoSource = fs.readFileSync(path.join(root, 'node_modules/expo-modules-core/ios/Core/JavaScriptUtils.swift'), 'utf8');

function functionSource(source, name) {
  const start = source.indexOf(`internal func ${name}<`);
  assert.ok(start >= 0, `Installed Expo must expose ${name}`);
  const body = source.indexOf('{', start);
  let depth = 0;
  for (let end = body; end < source.length; end += 1) {
    if (source[end] === '{') depth += 1;
    if (source[end] === '}' && --depth === 0) return source.slice(start, end + 1);
  }
  throw new Error(`Cannot extract installed Expo ${name}`);
}

const validatorSource = functionSource(expoSource, 'validateArgumentsNumber');
const predicate = validatorSource.match(/if\s+([^\n{]+)\s*\{/)[1].trim();
assert.match(predicate, /^[a-zA-Z\s<>=!&|()]+$/);
assert.deepEqual([...new Set(predicate.match(/[a-zA-Z]+/g))].sort(), ['argumentsCount', 'received', 'requiredArgumentsCount']);

function nativeContract(name) {
  const signature = moduleSource.match(new RegExp(`AsyncFunction\\("${name}"\\)\\s*\\{\\s*\\(([^)]*)\\)`));
  assert.ok(signature, `The real iOS ${name} definition must exist`);
  const parameters = signature[1].trim() ? signature[1].split(',').map((value) => value.trim()) : [];
  let required = parameters.length;
  while (required > 0 && parameters[required - 1].endsWith('?')) required -= 1;
  return { argumentsCount: parameters.length, requiredArgumentsCount: required };
}

function sharedCount(name) {
  const call = sharedSource.match(new RegExp(`module\\.${name}\\(([^)]*)\\)`));
  assert.ok(call, `The real shared ${name} call must exist`);
  return call[1].trim() ? call[1].split(',').length : 0;
}

// Swift and JavaScript have identical integer comparison/boolean operators in
// this SDK predicate. Execute the installed source condition without copying
// its policy; the optional Swift probe below also compiles the exact function.
function accepted(name, received) {
  return !vm.runInNewContext(predicate, { ...nativeContract(name), received }, { timeout: 1000 });
}

test('real shared iOS connect call satisfies installed Expo argument validation', () => {
  assert.equal(accepted('connect', sharedCount('connect')), true);
});

test('real shared iOS disconnect call satisfies installed Expo argument validation', () => {
  assert.equal(accepted('disconnect', sharedCount('disconnect')), true);
});

test('optional platform flags preserve older iOS calls and reject excess arguments', () => {
  assert.equal(accepted('connect', 1), true);
  assert.equal(accepted('disconnect', 0), true);
  for (const name of ['connect', 'disconnect']) {
    assert.equal(accepted(name, nativeContract(name).argumentsCount + 1), false);
  }
});

// The macOS lane explicitly selects its checked Xcode compiler. Generic Node
// checks do not invoke a host's optional Swift bootstrap or download shim.
const swift = process.env.VEX_SWIFTC;
const swiftVersion = swift ? spawnSync(swift, ['--version'], { encoding: 'utf8', timeout: 30_000 }) : null;
test('installed Expo Swift validator accepts the source-derived bridge calls', {
  skip: !swift ? 'Swift validator runs with the selected compiler in macOS CI' : false,
}, () => {
  assert.equal(swiftVersion.status, 0, swiftVersion.stderr || String(swiftVersion.error));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vex-ios-expo-args-'));
  try {
    const cases = [
      ['connect', sharedCount('connect'), true], ['disconnect', sharedCount('disconnect'), true],
      ['connect', 1, true], ['disconnect', 0, true],
      ['connect', nativeContract('connect').argumentsCount + 1, false],
      ['disconnect', nativeContract('disconnect').argumentsCount + 1, false],
    ].map(([name, count, expected]) => {
      const contract = nativeContract(name);
      return `("${name}", ${contract.argumentsCount}, ${contract.requiredArgumentsCount}, ${count}, ${expected})`;
    });
    const source = `
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
protocol AnyFunctionDefinition {
  var argumentsCount: Int { get }
  var requiredArgumentsCount: Int { get }
}
struct InvalidArgsNumberException: Error {
  init(_ value: (received: Int, expected: Int, required: Int)) {}
}
${validatorSource}
struct FunctionProbe: AnyFunctionDefinition {
  let argumentsCount: Int
  let requiredArgumentsCount: Int
}
let cases: [(String, Int, Int, Int, Bool)] = [${cases.join(',')}]
var failures = 0
for (name, maximum, minimum, received, expected) in cases {
  let function = FunctionProbe(argumentsCount: maximum, requiredArgumentsCount: minimum)
  let accepted: Bool
  do { try validateArgumentsNumber(function: function, received: received); accepted = true }
  catch { accepted = false }
  if accepted != expected { print("Expo bridge argument mismatch: \\(name) received=\\(received) min=\\(minimum) max=\\(maximum)"); failures += 1 }
}
if failures > 0 { exit(1) }
print("Installed Expo Swift argument validation: 6 cases passed")
`;
    const swiftFile = path.join(directory, 'ExpoArgumentProbe.swift');
    const executable = path.join(directory, 'ExpoArgumentProbe');
    fs.writeFileSync(swiftFile, source);
    const build = spawnSync(swift, ['-swift-version', '5', swiftFile, '-o', executable], { encoding: 'utf8', timeout: 60_000 });
    assert.equal(build.status, 0, build.stderr || String(build.error));
    const run = spawnSync(executable, [], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(run.status, 0, run.stdout + run.stderr || String(run.error));
    assert.match(run.stdout, /6 cases passed/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
