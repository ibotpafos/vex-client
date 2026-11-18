const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const ts = require('typescript');

const root = process.env.VEX_PAYMENT_SOURCE_ROOT || path.resolve(__dirname, '..');

// Exercise complete production modules; replace only native/HTTP boundaries.
function fixture({ response = {}, rejectOpen = false, requestError } = {}) {
  const opened = [], toasts = [], requests = [];
  const cache = new Map();
  const boundaries = {
    react: require('react'),
    'react/jsx-runtime': require('react/jsx-runtime'),
    'react-native': {
      StyleSheet: { create: value => value }, Text: 'Text', View: 'View',
      Platform: { OS: 'android' },
      Linking: { openURL: async url => {
        opened.push(url);
        if (rejectOpen) throw new Error('private-native-error fixture-session');
      } },
    },
    'expo-linking': { createURL: () => 'vexguard://auth/callback' },
    'expo-web-browser': {},
    '@/native/haptics': { playSelectionHaptic: () => {} },
    '@/ui/toast': { useToast: () => ({ showToast: value => toasts.push(value) }) },
    '@/ui/vex-ui': { VexPressable: 'VexPressable' },
  };
  function load(file) {
    const absolute = path.resolve(root, file);
    if (cache.has(absolute)) return cache.get(absolute);
    const module = { exports: {} };
    cache.set(absolute, module.exports);
    const compiled = ts.transpileModule(fs.readFileSync(absolute, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022,
        jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true },
      fileName: absolute,
    }).outputText;
    const localRequire = id => {
      if (Object.hasOwn(boundaries, id)) return boundaries[id];
      if (file === 'src/api/billing.ts' && id === './client') return {
        jsonRequest: async (...args) => {
          requests.push(args);
          if (requestError) throw requestError;
          return response;
        },
      };
      const next = id.startsWith('@/') ? path.join(root, 'src', id.slice(2))
        : id.startsWith('.') ? path.resolve(path.dirname(absolute), id) : null;
      assert.ok(next, `Unexpected dependency: ${id}`);
      const source = ['.ts', '.tsx'].map(extension => next + extension).find(fs.existsSync);
      assert.ok(source, `Missing production dependency: ${id}`);
      return load(path.relative(root, source));
    };
    new Function('require', 'module', 'exports', 'process', compiled)(localRequire, module, module.exports, { env: {} });
    return module.exports;
  }
  const Card = load('src/components/subscription-renewal-card.tsx').SubscriptionRenewalCard.type;
  return { opened, toasts, requests, load, render: entitlement => Card({ entitlement }),
    allowOpen: () => { rejectOpen = false; } };
}

function buttons(tree) {
  if (!tree || typeof tree !== 'object') return [];
  const children = [tree.props?.children].flat(Infinity);
  return [tree, ...children.flatMap(buttons)].filter(node => node.props?.accessibilityRole === 'button');
}

const inactive = { active: false, vpnAccess: false };

test('rendering renewal never opens a browser or starts a payment automatically', () => {
  const app = fixture();
  assert.equal(buttons(app.render(inactive)).length, 2);
  assert.deepEqual(app.opened, []);
  assert.deepEqual(app.requests, []);
});

test('renewal press goes through the real URL builder and native opener without credentials', async () => {
  const app = fixture();
  const renew = buttons(app.render(inactive))[0];
  assert.match(renew.props.accessibilityLabel, /Продлить VPN/);
  renew.props.onPress();
  await new Promise(setImmediate);
  assert.deepEqual(app.opened, ['https://vexguard.app/dashboard']);
  assert.deepEqual(app.toasts, []);
  assert.deepEqual(app.requests, []);
});

test('support press never routes to checkout', async () => {
  const app = fixture();
  buttons(app.render(inactive))[1].props.onPress();
  await new Promise(setImmediate);
  assert.deepEqual(app.opened, ['https://vexguard.app/support']);
});

test('browser rejection shows a safe error and a second press can retry', async () => {
  const app = fixture({ rejectOpen: true });
  const renew = buttons(app.render(inactive))[0];
  renew.props.onPress();
  await new Promise(setImmediate);
  assert.equal(app.toasts.length, 1);
  assert.equal(app.toasts[0].variant, 'error');
  assert.match(app.toasts[0].message, /Не удалось открыть сайт/);
  assert.doesNotMatch(JSON.stringify(app.toasts), /private-native-error|fixture-session/);
  app.allowOpen();
  renew.props.onPress();
  await new Promise(setImmediate);
  assert.equal(app.opened.length, 2);
  assert.equal(app.toasts.length, 1);
});

test('unknown and healthy access hide renewal, near expiry exposes the action', () => {
  const app = fixture();
  assert.equal(app.render(null), null);
  const active = { active: true, vpnAccess: true };
  assert.equal(app.render({ ...active, effectiveExpiresAt: new Date(Date.now() + 7 * 86400000).toISOString() }), null);
  assert.equal(buttons(app.render({ ...active, effectiveExpiresAt: new Date(Date.now() + 3600000).toISOString() })).length, 2);
});

test('website builder rejects external redirects and credential-bearing bases', () => {
  const app = fixture();
  const { vexWebsiteUrl } = app.load('src/navigation/website.ts');
  for (const value of ['//outside.invalid', '/\\outside.invalid', 'https://outside.invalid']) {
    assert.throws(() => vexWebsiteUrl(value));
  }
  assert.throws(() => vexWebsiteUrl('/dashboard', 'https://fixture-secret@vexguard.app'));
  assert.throws(() => vexWebsiteUrl('/dashboard', 'javascript:alert(1)'));
});

test('entitlement refresh preserves the server grant, grace expiry and cancellation signal', async () => {
  const app = fixture({ response: { active: true, vpn_access: true, plan_id: 'fixture-plan',
    current_period_end: '2026-11-01T00:00:00Z', effective_expires_at: '2026-11-03T00:00:00Z' } });
  const billing = app.load('src/api/billing.ts');
  const signal = new AbortController().signal;
  const result = await billing.entitlement('fixture-token', signal);
  assert.equal(result.active, true);
  assert.equal(result.vpnAccess, true);
  assert.equal(result.planId, 'fixture-plan');
  assert.equal(result.effectiveExpiresAt, '2026-11-03T00:00:00Z');
  assert.deepEqual(app.requests, [['/v1/billing/entitlement', { accessToken: 'fixture-token', suppressErrorLog: true, signal }]]);
  assert.equal(billing.hasPaidEntitlement(result), true);
});

test('unpaid or missing entitlement never activates VPN access', async () => {
  const app = fixture();
  const billing = app.load('src/api/billing.ts');
  const result = await billing.entitlement('fixture-token');
  assert.equal(result.active, false);
  assert.equal(result.vpnAccess, false);
  for (const value of [null, result, { active: true, vpnAccess: false }, { active: false, vpnAccess: true }]) {
    assert.equal(billing.hasPaidEntitlement(value), false);
  }
});

test('failed entitlement refresh propagates the failure rather than granting access', async () => {
  const failure = new Error('fixture-unauthorized');
  const app = fixture({ requestError: failure });
  await assert.rejects(app.load('src/api/billing.ts').entitlement('fixture-token'), error => error === failure);
  assert.deepEqual(app.opened, []);
});
