const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

// Execute whole real modules with isolated state; replace only explicit boundaries.
module.exports = function realSourceLoader({ env = {}, fetch = () => { throw new Error('Unadapted HTTP boundary'); }, expoFetch = fetch,
  platform = 'web', native = {}, appInfo = async () => ({}), adapters = {}, globals = {}, expose = {} } = {}) {
  const root = path.resolve(__dirname, '../..'), cache = new Map();
  const resolve = name => name.startsWith('@/') ? path.join(root, 'src', name.slice(2)) : name;
  const boundaries = new Map(Object.entries({
    'react-native': { Platform: { OS: platform, Version: 36 }, NativeModules: { VexVpn: native } },
    'expo/fetch': { fetch: expoFetch },
    'expo-secure-store': { getItemAsync: async () => null, setItemAsync: async () => {}, deleteItemAsync: async () => {} },
    '@/native/appInfo': { getAppInfo: appInfo, getOrCreateDeviceId: async () => 'fixture', VEX_API_CLIENT_VERSION: 'fixture-api', VEX_CONFIG_SCHEMA_VERSION: 1 },
    '@/native/vexVpn': { supportsNativeRoutingPolicy: () => false, supportsNativeVless: () => false },
    '@/native/deviceIdentity': { getOrCreateDeviceIdentity: async () => null },
    ...adapters,
  }).map(([name, value]) => [resolve(name), value]));
  function load(name) {
    const file = resolve(name);
    if (boundaries.has(file)) return boundaries.get(file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const filename = file + '.ts';
    const symbols = expose[path.relative(root, file)] ?? [];
    const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText;
    const requireFixture = id => {
      if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
      if (id.startsWith('@/') || boundaries.has(id)) return load(id);
      throw new Error(`Unadapted boundary ${id} from ${filename}`);
    };
    new Function('require', 'module', 'exports', 'process', 'fetch', '__DEV__', ...Object.keys(globals), code + `;Object.assign(module.exports, {${symbols.join(',')}});`)(
      requireFixture, module, module.exports, { env }, fetch, false, ...Object.values(globals));
    return module.exports;
  }
  return load;
};
