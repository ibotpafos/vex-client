const { Buffer } = require('node:buffer');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const test = require('node:test');
const ts = require('typescript');
const networkFetch = globalThis.fetch;
const settle = () => new Promise(resolve => setImmediate(resolve));
const frame = (id = 'devices:7', extra = '') =>
  `event: customer.change\nid: ${id}\ndata: ${JSON.stringify({ domain: 'devices', version: 7, extra })}\n\n`;

// Load actual production modules. Only the platform/Expo native boundary is
// adapted. The old default XHR boundary uses real fetch with automatic redirects,
// just as the inspected RN sendRequest path has no per-request redirect mode.
function transport(fetch, { legacyFetch = fetch, flag, platform = 'android', decoder = TextDecoder, ...options } = {}) {
  const modules = new Map(), calls = [], events = [], statuses = [], timers = new Map();
  let nextTimer = 0, revoked = 0, xhrCalls = 0;
  class XHRBoundary {
    responseText = ''; readyState = 1; status = 0; headers = {};
    controller = new AbortController();
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(name, value) { this.headers[name] = value; }
    abort() { this.controller.abort(); this.onabort?.(); }
    send() {
      xhrCalls++;
      void (async () => {
        try {
          const response = await fetch(this.url, { method: this.method, headers: this.headers, signal: this.controller.signal });
          if (this.controller.signal.aborted) return;
          this.readyState = 2; this.status = response.status; this.onreadystatechange?.();
          if (this.controller.signal.aborted) return;
          const reader = response.body?.getReader(), decoder = new TextDecoder();
          if (reader) {
            try {
              while (!this.controller.signal.aborted) {
                const chunk = await reader.read();
                if (chunk.done) break;
                this.responseText += decoder.decode(chunk.value, { stream: true });
                this.onprogress?.();
              }
            } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
          }
          if (!this.controller.signal.aborted) this.onload?.();
        } catch { if (!this.controller.signal.aborted) this.onerror?.(); }
      })();
    }
  }
  function load(relative) {
    if (modules.has(relative)) return modules.get(relative).exports;
    const module = { exports: {} }; modules.set(relative, module);
    const filename = path.join(__dirname, '../src', relative + '.ts');
    const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    function requireFixture(id) {
      if (id === 'react-native') return { Platform: { OS: platform } };
      if (id === 'expo/fetch') return { fetch: legacyFetch };
      const target = path.posix.normalize(path.posix.join(path.posix.dirname(relative), id));
      assert.ok(['realtime/customerRealtimeCore', 'api/apiFetch'].includes(target), 'Unexpected transport dependency');
      return load(target);
    }
    const observedFetch = (url, init) => { calls.push({ url, init }); return fetch(url, init); };
    new Function('module', 'exports', 'require', 'fetch', 'XMLHttpRequest', 'TextDecoder', 'process', source)(
      module, module.exports, requireFixture, observedFetch, XHRBoundary, decoder,
      { env: { EXPO_PUBLIC_USE_RN_FETCH: flag } },
    );
    return module.exports;
  }
  const { CustomerRealtimeTransport } = load('realtime/customerRealtimeTransport');
  const instance = new CustomerRealtimeTransport({
    baseUrl: 'https://fixture.example.test/prefix/', accessToken: 'fixture-token',
    onEvent(event) { events.push(event); options.onEvent?.(instance, event); },
    onStatus(connected) { statuses.push(connected); options.onStatus?.(instance, connected); },
    onSessionRevoked() { revoked++; },
    schedule(callback, milliseconds) { const id = ++nextTimer; timers.set(id, { callback, milliseconds }); return id; },
    cancelSchedule(id) { timers.delete(id); },
    ...Object.fromEntries(Object.entries(options).filter(([name]) => !['onEvent', 'onStatus'].includes(name))),
  });
  return {
    instance, calls, events, statuses, timers,
    get revoked() { return revoked; }, get xhrCalls() { return xhrCalls; },
    start() { instance.start(); }, stop() { instance.stop(); assert.equal(timers.size, 0); },
    fire(milliseconds) {
      const entry = [...timers].find(([, timer]) => timer.milliseconds === milliseconds);
      assert.ok(entry, `Expected ${milliseconds}ms timer`); timers.delete(entry[0]); entry[1].callback();
    },
  };
}
async function until(ready) {
  const deadline = Date.now() + 2_000;
  while (!ready()) { assert.ok(Date.now() < deadline, 'fixture condition timed out'); await settle(); }
}

test('Node timer objects return to the matching cancellation hook', async () => {
  const fixture = streamResponse();
  const scheduled = [], cancelled = [];
  const h = transport(async () => fixture.response, {
    schedule(callback, milliseconds) {
      const timer = setTimeout(callback, milliseconds);
      scheduled.push(timer);
      return timer;
    },
    cancelSchedule(timer) {
      cancelled.push(timer);
      clearTimeout(timer);
    },
  });
  try {
    h.start();
    await until(() => fixture.body.locked);
    assert.equal(scheduled.length, 1);
    assert.equal(typeof scheduled[0], 'object');
    h.stop();
    assert.deepEqual(cancelled, scheduled);
    assert.equal(fixture.body.locked, false);
  } finally {
    h.stop();
    for (const timer of scheduled) clearTimeout(timer);
  }
});

async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  assert.equal(server.address().address, '127.0.0.1');
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}
async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}
function streamResponse() {
  let controller, cancelled = 0;
  const body = new ReadableStream({ start(value) { controller = value; }, cancel() { cancelled++; } });
  return { response: { status: 200, body }, body, push: bytes => controller.enqueue(bytes), end: () => controller.close(), get cancelled() { return cancelled; } };
}

for (const status of [301, 302, 303, 307, 308]) for (const foreign of [false, true]) {
  test(`SSE ${status} ${foreign ? 'foreign' : 'same'} authority never opens a redirect target`, async () => {
    let original = 0, forwarded = 0;
    const sink = await listen((_request, response) => { forwarded++; response.end(frame()); });
    let origin, h;
    try {
      origin = await listen((request, response) => {
        if (request.url.startsWith('/target')) { forwarded++; response.end(frame()); return; }
        original++; assert.equal(request.url, '/prefix/v1/events');
        assert.equal(request.headers.authorization, 'Bearer fixture-token');
        response.writeHead(status, { Location: `${foreign ? sink.url : origin.url}/target` }); response.end(frame());
      });
      h = transport(networkFetch, { baseUrl: origin.url + '/prefix' }); h.start();
      await until(() => [...h.timers.values()].some(timer => timer.milliseconds === 1_000));
      assert.equal(original, 1); assert.equal(forwarded, 0, 'Redirect target received realtime work');
      assert.equal(h.events.length, 0); assert.equal(h.revoked, 0); assert.equal(h.statuses.includes(true), false);
    } finally { h?.stop(); if (origin) await close(origin.server); await close(sink.server); }
  });
}

for (const flag of [undefined, '1', 'true']) for (const platform of ['android', 'web']) {
  test(`${platform} flag=${flag} shares manual fetch policy and closes opaque/unread responses`, async () => {
    let native = 0, global = 0, signal, redirect, bodyReads = 0;
    const reject = async (_url, init) => {
      signal = init.signal; redirect = init.redirect;
      return { status: 0, type: 'opaqueredirect', get body() { bodyReads++; throw new Error('A blocked redirect body must not be opened'); } };
    };
    const h = transport((...args) => { global++; return reject(...args); }, {
      flag, platform, legacyFetch: (...args) => { native++; return reject(...args); },
    });
    try {
      h.start(); await until(() => [...h.timers.values()].some(timer => timer.milliseconds === 1_000));
      const legacy = platform !== 'web' && flag !== undefined;
      assert.equal(global, legacy ? 0 : 1); assert.equal(native, legacy ? 1 : 0);
      assert.equal(redirect, 'manual'); assert.equal(bodyReads, 0);
      assert.equal(signal.aborted, true); assert.equal(h.events.length, 0); assert.equal(h.revoked, 0);
    } finally { h.stop(); }
  });
}

test('streaming UTF8 and split CRLF reuse the bounded parser without accumulating responseText', async () => {
  const fixture = streamResponse();
  const h = transport(async () => fixture.response);
  try {
    h.start(); await until(() => fixture.body.locked);
    const wire = Buffer.from(frame('unicode', 'Привет 👨‍👩‍👧‍👦 e\u0301').replaceAll('\n', '\r\n'));
    for (const byte of wire) { fixture.push(Uint8Array.of(byte)); await settle(); }
    assert.equal(h.events[0].id, 'unicode'); assert.equal(h.events[0].data, JSON.stringify({ domain: 'devices', version: 7, extra: 'Привет 👨‍👩‍👧‍👦 e\u0301' }));
    const comments = Buffer.from(':' + 'x'.repeat(1_000) + '\n\n');
    for (let count = 0; count < 1_100; count++) { fixture.push(comments); await settle(); }
    fixture.push(Buffer.from(frame('after-megabyte'))); await until(() => h.events.length === 2);
    assert.deepEqual(h.events.map(event => event.id), ['unicode', 'after-megabyte']);
    assert.equal(h.xhrCalls, 0); assert.equal(h.calls.length, 1);
    assert.equal([...h.timers.values()].some(timer => timer.milliseconds === 1_000), false);
    fixture.push(Buffer.from(frame('incomplete').slice(0, -1))); fixture.end();
    await until(() => !fixture.body.locked);
    assert.equal(h.events.length, 2);
  } finally { h.stop(); }
});

test('oversized frame cancels the reader and reconnects with the last delivered cursor', async () => {
  const first = streamResponse(), second = streamResponse(), requests = [];
  const h = transport(async (url, init) => { requests.push({ url, init }); return requests.length === 1 ? first.response : second.response; });
  try {
    h.start(); await until(() => first.body.locked);
    first.push(Buffer.from(frame('devices:9223372036854775807') + 'x'.repeat(70_000) + '\n\n' + frame('suffix')));
    await until(() => first.cancelled === 1 && !first.body.locked);
    assert.deepEqual(h.events.map(event => event.id), ['devices:9223372036854775807']);
    assert.equal(requests[0].init.signal.aborted, true); h.fire(1_000); await until(() => second.body.locked);
    assert.equal(requests[1].url, 'https://fixture.example.test/prefix/v1/events');
    assert.equal(requests[1].init.headers['Last-Event-ID'], 'devices:9223372036854775807');
    assert.equal(requests[1].init.headers.Authorization, 'Bearer fixture-token');
    second.push(Buffer.from(frame('fresh'))); await until(() => h.events.length === 2);
    assert.deepEqual(h.events.map(event => event.id), ['devices:9223372036854775807', 'fresh']);
  } finally { h.stop(); await settle(); assert.equal(second.body.locked, false); }
});

for (const where of ['status', 'event']) {
  test(`stop from ${where} cancels buffered delivery without advancing the cursor`, async () => {
    const first = streamResponse(), second = streamResponse(), requests = [];
    let stopped = false;
    const stop = instance => { if (!stopped) { stopped = true; instance.stop(); } };
    const h = transport(async (_url, init) => { requests.push(init); return requests.length === 1 ? first.response : second.response; }, {
      ...(where === 'status' ? { onStatus(instance, connected) { if (connected) stop(instance); } } : { onEvent: stop }),
    });
    try {
      h.start(); await until(() => first.body.locked); first.push(Buffer.from(frame('first') + frame('retired')));
      await until(() => first.cancelled === 1 && !first.body.locked);
      assert.equal(h.events.length, where === 'status' ? 0 : 1); assert.equal(h.timers.size, 0);
      h.start(); await until(() => second.body.locked);
      assert.equal(requests[1].headers['Last-Event-ID'], where === 'status' ? undefined : 'first');
    } finally { h.stop(); await settle(); }
  });
}

test('stop retires late headers and a pending body read without retaining the stream lock', async () => {
  const late = streamResponse(); let resolve;
  const h = transport(() => new Promise(ready => { resolve = ready; }));
  h.start(); h.stop(); resolve(late.response); await until(() => late.cancelled === 1);
  assert.equal(late.body.locked, false); assert.deepEqual(h.events, []); assert.equal(h.timers.size, 0);
  const pending = streamResponse(), active = transport(async () => pending.response);
  active.start(); await until(() => pending.body.locked); active.stop();
  await until(() => pending.cancelled === 1 && !pending.body.locked);
  assert.equal(active.timers.size, 0); assert.equal(active.revoked, 0);
});

test('watchdog owns stalled headers and a pending stream read', async () => {
  let headersSignal;
  const h = transport((_url, init) => { headersSignal = init.signal; return new Promise(() => {}); });
  try { h.start(); h.fire(45_000); assert.equal(headersSignal.aborted, true); assert.equal(h.timers.size, 1); }
  finally { h.stop(); }
  const pending = streamResponse(), active = transport(async () => pending.response);
  try {
    active.start(); await until(() => pending.body.locked); active.fire(45_000);
    await until(() => pending.cancelled === 1 && !pending.body.locked);
    assert.equal([...active.timers.values()].filter(timer => timer.milliseconds === 1_000).length, 1);
  } finally { active.stop(); }
});

test('installed Expo UTF8 decoder preserves fragmented native stream bytes', async () => {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(path.join(__dirname, '../node_modules/expo/src/winter/TextDecoder.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  new Function('module', 'exports', source)(module, module.exports);
  const fixture = streamResponse(), h = transport(async () => fixture.response, { decoder: module.exports.TextDecoder });
  try {
    h.start(); await until(() => fixture.body.locked);
    const text = 'Привет 👨‍👩‍👧‍👦 e\u0301';
    for (const byte of Buffer.from(frame('native-decoder', text))) { fixture.push(Uint8Array.of(byte)); await settle(); }
    assert.equal(h.events.length, 1); assert.equal(JSON.parse(h.events[0].data).extra, text);
    assert.equal(h.xhrCalls, 0);
  } finally { h.stop(); await settle(); assert.equal(fixture.body.locked, false); }
});

for (const status of [200, 302]) {
  test(`real HTTP ${status} unread stream closes on watchdog or redirect rejection`, async () => {
    let closed = 0, forwarded = 0, received = 0;
    const fixture = await listen((request, response) => {
      if (request.url === '/target') { forwarded++; response.end(frame()); return; }
      received++; response.on('close', () => { closed++; });
      response.writeHead(status, { 'Content-Type': 'text/event-stream', ...(status === 302 ? { Location: '/target' } : {}) });
      response.flushHeaders(); // Keep body open; only client cancellation closes it.
    });
    const h = transport(networkFetch, { baseUrl: fixture.url });
    try {
      h.start(); await until(() => received === 1);
      if (status === 200) h.fire(45_000);
      await until(() => closed === 1);
      assert.equal(forwarded, 0); assert.equal(h.events.length, 0);
      assert.equal(h.revoked, 0);
      await until(() => [...h.timers.values()].some(timer => timer.milliseconds === 1_000));
    } finally { h.stop(); await close(fixture.server); }
  });
}

for (const status of [200, 204, 401, 403, 503]) {
  test(`HTTP ${status} preserves realtime status/session rejection without reading an invalid body`, async () => {
    let signal, bodyReads = 0;
    const h = transport(async (_url, init) => {
      signal = init.signal;
      return { status, body: status === 200 ? null : { getReader() { bodyReads++; throw new Error('Unexpected body read'); } } };
    });
    try {
      h.start(); await until(() => h.statuses.length > 0);
      assert.equal(signal.aborted, true); assert.equal(h.revoked, status === 401 ? 1 : 0);
      assert.equal(h.events.length, 0); assert.equal(bodyReads, 0);
      assert.equal([...h.timers.values()].filter(timer => timer.milliseconds === 1_000).length, status === 401 ? 0 : 1);
    } finally { h.stop(); }
  });
}
