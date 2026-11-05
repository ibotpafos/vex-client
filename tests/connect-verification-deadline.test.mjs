import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification.ts';

const ts = createRequire(import.meta.url)('typescript');

function loadNativeAdapter(statusReads) {
  let reads = 0;
  let listener;
  const clock = class extends Date { static now() { return 1_000_000; } };
  const disconnected = { state: 'disconnected', rxBytes: 0, txBytes: 0 };
  const native = {
    connect: async () => ({ state: 'connected', rxBytes: 0, txBytes: 0 }),
    disconnect: async () => disconnected,
    status: async () => {
      const value = statusReads[reads++];
      assert.ok(value, 'Unexpected native status read');
      return typeof value === 'function' ? value() : value;
    },
  };
  function load(relativePath, dependencies = {}) {
    const exports = {};
    const source = readFileSync(new URL(relativePath, import.meta.url), 'utf8');
    vm.runInNewContext(ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText, {
      exports, Date: clock,
      require: name => { assert.ok(Object.hasOwn(dependencies, name), `Unexpected native adapter import ${name}`); return dependencies[name]; },
    });
    return exports;
  }
  const adapter = load('../src/native/vexVpn.ts', {
    'react-native': {
      Platform: { OS: 'android' }, NativeModules: { VexVpn: native },
      NativeEventEmitter: class { addListener(_event, callback) { listener = callback; return { remove() {} }; } },
    },
    expo: {},
    '@/vpn/disconnectRecovery': { disconnectWithRecoveryTimeout: operation => operation },
    '@/vpn/vpnStatusVerification': load('../src/vpn/vpnStatusVerification.ts'),
    '@/vpn/nativeRoutingPolicy': load('../src/vpn/nativeRoutingPolicy.ts'),
  });
  return { adapter, reads: () => reads, emit: status => listener(status), clock };
}

function deferred() {
  let resolve;
  const promise = new Promise(ok => { resolve = ok; });
  return { promise, resolve };
}

const pending = { state: 'connected', rxBytes: 0, txBytes: 0, verified: false };

test('an already canceled operation cannot accept an initial verified status', async () => {
  const canceled = new Error('operation superseded');
  await assert.rejects(waitForVerifiedVpnConnection({ ...pending, verified: true }, async () => pending, {
    assertCurrent: () => { throw canceled; },
  }), error => error === canceled);
});

test('cancellation during a poll delay prevents the next native read', async () => {
  let current = true, reads = 0;
  const canceled = new Error('operation superseded');
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => {
    reads++;
    return { ...pending, verified: reads > 1 };
  }, {
    assertCurrent: () => { if (!current) throw canceled; },
    wait: async () => { current = false; },
  }), error => error === canceled);
  assert.equal(reads, 1);
});

test('a native status returned after cancellation cannot publish a fresh handshake', async () => {
  let current = true;
  const canceled = new Error('operation superseded');
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => {
    current = false;
    return { ...pending, verified: true };
  }, { assertCurrent: () => { if (!current) throw canceled; } }), error => error === canceled);
});

for (const state of ['connecting', 'verifying']) {
  test(`an initial ${state} status without verification fields cannot return early`, async () => {
    let reads = 0;
    const result = await waitForVerifiedVpnConnection({ state, rxBytes: 0, txBytes: 0 }, async () => {
      reads++;
      return { ...pending, verified: true };
    });
    assert.equal(reads, 1);
    assert.equal(result.state, 'connected');
  });

  test(`an initial ${state} status waits for a fresh verified connection`, async () => {
    let reads = 0;
    const result = await waitForVerifiedVpnConnection({ ...pending, state, verified: true }, async () => {
      reads++;
      return reads === 1
        ? { ...pending, state }
        : { ...pending, verified: true, latestHandshakeEpochMillis: 1000 };
    }, { minimumHandshakeEpochMillis: 1000, pollMs: 0 });
    assert.equal(reads, 2);
    assert.equal(result.state, 'connected');
    assert.equal(result.latestHandshakeEpochMillis, 1000);
  });

  test(`an initial ${state} status retains the verification deadline`, async () => {
    await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state }, () => new Promise(() => {}), {
      timeoutMs: 20,
    }), /VPN handshake timed out/);
  });
}

for (const state of ['disconnected', 'disconnecting', 'error']) {
  test(`an initial ${state} status rejects without polling`, async () => {
    let reads = 0;
    await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state }, async () => {
      reads++;
      return { ...pending, verified: true };
    }), /VPN backend did not enter/);
    assert.equal(reads, 0);
  });
}

test('an iOS extension may still be connecting when startVPNTunnel returns', async () => {
  const result = await waitForVerifiedVpnConnection({ ...pending, state: 'connecting' }, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: 1000,
  }), { minimumHandshakeEpochMillis: 1000, pollMs: 0 });
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('a starting extension still needs a handshake before the same deadline', async () => {
  await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state: 'connecting' }, async () => ({
    ...pending, state: 'connecting',
  }), { attempts: 2, pollMs: 0 }), /VPN handshake timed out/);
});

test('a ready fresh handshake is read before the first polling delay', async () => {
  const result = await waitForVerifiedVpnConnection(pending, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: 1000,
  }), {
    minimumHandshakeEpochMillis: 1000,
    wait: async () => { throw new Error('unnecessary initial polling delay'); },
  });
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('an old handshake still waits and cannot satisfy a new attempt', async () => {
  let reads = 0;
  let waits = 0;
  const result = await waitForVerifiedVpnConnection(pending, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: ++reads === 1 ? 900 : 1000,
  }), {
    minimumHandshakeEpochMillis: 1000,
    wait: async () => { waits++; },
  });
  assert.equal(waits, 1);
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('a stalled native status read cannot hold connection verification forever', async () => {
  const verification = waitForVerifiedVpnConnection(pending, () => new Promise(() => {}), {
    pollMs: 0, timeoutMs: 20,
  });
  let safetyTimer;
  const safety = new Promise((_, reject) => {
    safetyTimer = setTimeout(() => reject(new Error('test safety deadline exceeded')), 500);
  });
  try {
    await assert.rejects(Promise.race([verification, safety]), /VPN handshake timed out/);
  } finally { clearTimeout(safetyTimer); }
});

test('a status returned after suspension cannot be accepted beyond the deadline', async () => {
  let now = 100;
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => {
    now += 60_000;
    return { ...pending, verified: true };
  }, { pollMs: 0, timeoutMs: 1000, now: () => now }), /VPN handshake timed out/);
});

test('a current handshake within the deadline succeeds', async () => {
  const status = await waitForVerifiedVpnConnection(pending, async () => ({ ...pending, verified: true }), {
    pollMs: 0, timeoutMs: 1000,
  });
  assert.equal(status.verified, true);
});

test('connect verification reads a ready native handshake without the Android cache delay', async () => {
  const verified = { ...pending, latestHandshakeEpochMillis: 1_000_000 };
  const f = loadNativeAdapter([{ state: 'disconnected', rxBytes: 0, txBytes: 0 }, verified]);
  const source = readFileSync(new URL('../src/vpn/useVpnConnectionFlow.ts', import.meta.url), 'utf8');
  const tree = ts.createSourceFile('flow.ts', source, ts.ScriptTarget.Latest, true);
  let callback;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && node.name.getText(tree) === 'connectProfileWithEndpointFallback') {
      callback = node.initializer.arguments[0].getText(tree);
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  assert.ok(callback);
  const context = {
    ...f.adapter, Date: f.clock, Platform: { OS: 'android' }, session: null,
    requireCurrentSession() {}, antiLeakEnabled: true,
    vpnProfileAddressMatchesDevice: () => true, androidVpnProfileWithinBinderBudget: () => true,
    getVpnApplicationSelection: async () => ({ mode: 'all', packageNames: [] }),
    dynamicRouteRuntime: { attempts: profile => [{ profile }], clearActive() {} },
    profileEndpoint: () => 'fixture:443', withLastSuccessfulEndpoint: profile => profile,
    withTimeout: promise => promise, connectAttemptTimeoutMs: 25_000,
    waitForVerifiedVpnConnection: (status, readStatus, options) => waitForVerifiedVpnConnection(status, readStatus, {
      ...options, wait: async () => { throw new Error('A cached pending status forced an unnecessary polling delay'); },
    }),
    isVpnTransportFallbackError: () => false,
  };
  const code = ts.transpileModule(`return (${callback});`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  const connect = new Function(...Object.keys(context), code)(...Object.values(context));
  const result = await connect({ config: 'fixture' });
  assert.equal(result.status.latestHandshakeEpochMillis, 1_000_000);
  assert.equal(result.status.verified, true);
  assert.equal(f.reads(), 2);
  await f.adapter.getVpnStatus();
  assert.equal(f.reads(), 2, 'normal background reads retain the status cache');
});

test('fresh Android status reads still reject the previous handshake', async () => {
  const f = loadNativeAdapter([
    { ...pending, latestHandshakeEpochMillis: 999_000 },
    { ...pending, latestHandshakeEpochMillis: 1_000_000 },
  ]);
  const started = await f.adapter.connectVpn('fixture');
  let waits = 0;
  const result = await waitForVerifiedVpnConnection(started, () => f.adapter.getVpnStatus({ fresh: true }), {
    minimumHandshakeEpochMillis: 998_000, previousHandshakeEpochMillis: 999_000,
    wait: async () => { waits++; },
  });
  assert.equal(waits, 1);
  assert.equal(result.latestHandshakeEpochMillis, 1_000_000);
});

for (const resolveOldFirst of [true, false]) {
  test(`an older status read cannot replace or clear a fresh read (older completes first: ${resolveOldFirst})`, async () => {
    const old = deferred(), fresh = deferred();
    const f = loadNativeAdapter([() => old.promise, () => fresh.promise]);
    const oldRead = f.adapter.getVpnStatus();
    const freshRead = f.adapter.getVpnStatus({ fresh: true });
    const verified = { ...pending, latestHandshakeEpochMillis: 1_000_000 };
    let joined;
    if (resolveOldFirst) {
      old.resolve(pending); await oldRead;
      joined = f.adapter.getVpnStatus();
      assert.equal(f.reads(), 2, 'old completion must not clear the newer in-flight read');
    }
    fresh.resolve(verified); await freshRead; await joined;
    if (!resolveOldFirst) { old.resolve(pending); await oldRead; }
    assert.equal((await f.adapter.getVpnStatus()).latestHandshakeEpochMillis, 1_000_000);
    assert.equal(f.reads(), 2, 'old completion must not replace the fresh cache');
  });
}

for (const mutation of ['connect', 'disconnect', 'event']) {
  test(`an older native status read cannot replace a newer ${mutation} snapshot`, async () => {
    const old = deferred();
    const f = loadNativeAdapter([() => old.promise]);
    const oldRead = f.adapter.getVpnStatus();
    let expected;
    if (mutation === 'connect') expected = await f.adapter.connectVpn('fixture');
    if (mutation === 'disconnect') expected = await f.adapter.disconnectVpn();
    if (mutation === 'event') {
      f.adapter.listenVpnStatusChanged(() => {});
      f.emit({ ...pending, latestHandshakeEpochMillis: 1_000_000 });
      expected = await f.adapter.getVpnStatus();
    }
    old.resolve({ ...pending, state: 'error' }); await oldRead;
    assert.equal((await f.adapter.getVpnStatus()).state, expected.state);
    assert.equal((await f.adapter.getVpnStatus()).latestHandshakeEpochMillis, expected.latestHandshakeEpochMillis);
    assert.equal(f.reads(), 1);
  });
}
for (const timeoutMs of [10_000, 15_000]) {
  test(`default polling uses the ${timeoutMs}ms deadline for a delayed fresh handshake`, async () => {
    let now = 0;
    let reads = 0;
    const freshAt = timeoutMs - 1000;
    const result = await waitForVerifiedVpnConnection(pending, async () => {
      reads++;
      return { ...pending, verified: now >= freshAt, latestHandshakeEpochMillis: now };
    }, {
      timeoutMs,
      minimumHandshakeEpochMillis: freshAt,
      now: () => now,
      wait: async (delayMs) => { now += delayMs; },
    });
    assert.equal(result.verified, true);
    assert.equal(now, freshAt);
    assert.ok(reads > 20, 'the old implicit attempt cap must not preempt the deadline');
  });
}

test('an unresponsive peer exhausts the deadline without accepting a stale handshake', async () => {
  let now = 0;
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: 1000,
  }), {
    timeoutMs: 10_000,
    minimumHandshakeEpochMillis: 2000,
    now: () => now,
    wait: async (delayMs) => { now += delayMs; },
  }), /VPN handshake timed out/);
  assert.equal(now, 10_000);
});

test('an explicit attempt limit remains a caller-controlled bound', async () => {
  let now = 0;
  let reads = 0;
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => {
    reads++;
    return pending;
  }, {
    attempts: 2,
    timeoutMs: 10_000,
    now: () => now,
    wait: async (delayMs) => { now += delayMs; },
  }), /VPN handshake timed out/);
  assert.equal(reads, 2);
  assert.equal(now, 250);
});
