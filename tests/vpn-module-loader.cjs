const { Buffer } = require('node:buffer');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');

// A fresh graph per fixture; real local imports, explicit platform/API adapters.
function loadModule(file, dependencies = {}, globals = {}, bindings = {}) {
  const cache = new Map();
  function resolve(name, parent) {
    const base = name.startsWith('@/') ? path.join(root, 'src', name.slice(2)) : path.resolve(path.dirname(parent), name);
    const found = [base, base + '.ts', base + '.tsx', base + '.cjs', path.join(base, 'index.ts')]
      .find(candidate => fs.existsSync(candidate) && fs.statSync(candidate).isFile());
    assert.ok(found, `Unresolved local import ${name} from ${parent}`);
    return found;
  }
  function evaluate(filename, entry = false) {
    if (cache.has(filename)) return cache.get(filename).exports;
    const module = { exports: {} };
    cache.set(filename, module);
    const source = fs.readFileSync(filename, 'utf8');
    const tree = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true);
    const imports = new Map();
    const namespaces = new Set();
    for (const node of tree.statements) {
      if (!ts.isImportDeclaration(node) || !node.importClause || node.importClause.isTypeOnly) continue;
      const clause = node.importClause;
      const values = {};
      if (clause.namedBindings && ts.isNamespaceImport(clause.namedBindings)) {
        if (Object.hasOwn(bindings, clause.namedBindings.name.text)) { imports.set(node.moduleSpecifier.text, bindings[clause.namedBindings.name.text]); namespaces.add(node.moduleSpecifier.text); }
      } else {
        for (const item of clause.namedBindings?.elements ?? []) {
          if (!item.isTypeOnly && Object.hasOwn(bindings, item.name.text)) values[item.propertyName?.text ?? item.name.text] = bindings[item.name.text];
        }
        if (clause.name && Object.hasOwn(bindings, clause.name.text)) values.default = bindings[clause.name.text];
        if (Object.keys(values).length) imports.set(node.moduleSpecifier.text, { ...imports.get(node.moduleSpecifier.text), ...values });
      }
    }
    const localRequire = name => {
      if (entry && Object.hasOwn(dependencies, name)) return dependencies[name];
      const overrides = imports.get(name);
      if (namespaces.has(name)) return overrides;
      let real;
      const actual = () => {
        if (real) return real;
        if (name.startsWith('.') || name.startsWith('@/')) return real = evaluate(resolve(name, filename));
        assert.ok(name.startsWith('node:') || name.startsWith('@noble/'), `Unmocked external import ${name} from ${filename}`);
        return real = require(name);
      };
      // Unused platform exports do not initialize native SDKs in Node.
      return new Proxy({}, {
        get: (_, key) => key === '__esModule' ? true : overrides && Object.hasOwn(overrides, key) ? overrides[key] : actual()[key],
        ownKeys: () => Reflect.ownKeys(actual()),
        getOwnPropertyDescriptor: (_, key) => Object.hasOwn(actual(), key) ? { configurable: true, enumerable: true, value: actual()[key] } : undefined,
      });
    };
    const code = ts.transpileModule(source, { fileName: filename, compilerOptions: {
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX,
    } }).outputText;
    vm.compileFunction(code, ['exports', 'require', 'module', '__filename', '__dirname'], {
      filename, contextExtensions: [globals],
    })(module.exports, localRequire, module, filename, path.dirname(filename));
    return module.exports;
  }
  return evaluate(path.isAbsolute(file) ? file : path.join(root, file), true);
}
function loadWithBindings(file, names, bindings = {}, globals = {}) {
  const module = loadModule(file, {}, globals, bindings);
  if (!names) return module;
  const result = {};
  for (const name of names.split(',')) {
    assert.ok(Object.hasOwn(module, name), `Missing real export ${name} from ${file}`);
    result[name] = module[name];
  }
  return result;
}
module.exports = { loadModule, loadWithBindings };

// A confirmed account in SecureStore, not a replacement for key admission.
function accountFixture({ owner = 'A', platform = 'android', deviceId = `device-${owner}`, externalDeviceId = 'physical' } = {}) {
  const keyPair = { publicKey: Buffer.alloc(32, 1).toString('base64'), privateKey: Buffer.alloc(32, 2).toString('base64'), keyEpoch: 2 };
  const keyScope = 'fixture-account-key';
  const saved = new Map([
    ['vex.vpn.account_registration.v1.' + Buffer.from(owner).toString('hex'), JSON.stringify({ version: 1, installationId: externalDeviceId, externalDeviceId, keyScope, confirmedDeviceId: deviceId, legacyRegistrationPending: false })],
    ['vex.vpn.account_keys.v1.' + keyScope, JSON.stringify({ ...keyPair, confirmedKeyDeviceId: deviceId })],
  ]);
  const SecureStore = {
    getItemAsync: async name => saved.get(name) ?? null,
    setItemAsync: async (name, value) => { saved.set(name, value); },
    deleteItemAsync: async name => { saved.delete(name); },
  };
  const api = loadWithBindings('src/api/vpn.ts', null, {
    Platform: { OS: platform }, SecureStore,
    me: async () => ({ id: owner }),
    jsonRequest: async route => { throw new Error(`Unexpected admission API request ${route}`); },
  });
  return { api, keyPair, saved, device: { id: deviceId, userId: owner, status: 'active', externalDeviceId, platform, protocol: 'amneziawg', provisioningMode: 'managed_native', clientKeyOwnership: 'client', publicKey: keyPair.publicKey, keyEpoch: keyPair.keyEpoch } };
}
module.exports.accountFixture = accountFixture;
