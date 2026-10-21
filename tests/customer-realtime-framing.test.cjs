const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require('typescript');

function load(name) {
  const module = { exports: {} };
  const filename = path.join(__dirname, '../src/realtime', name + '.ts');
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(source, {
    module, exports: module.exports, Set, JSON,
    require(id) {
      assert.ok(['./customerRealtimeCore', '../api/apiFetch'].includes(id), 'Only actual realtime and fetch modules may be imported');
      return load(id);
    },
  }, { filename });
  return module.exports;
}
const { CustomerRealtimeTransport } = load('customerRealtimeTransport');
const limit = 64 * 1024;
const frame = (id = 'devices:7', extra = '') =>
  `event: customer.change\nid: ${id}\ndata: ${JSON.stringify({ domain: 'devices', version: 7, extra })}\n\n`;
const plain = value => JSON.parse(JSON.stringify(value));

function harness(callbacks = {}) {
  const requests = [], events = [], statuses = [], timers = new Map();
  let timerID = 0, revoked = 0;
  const transport = new CustomerRealtimeTransport({
    accessToken: 'fixture-token', baseUrl: 'https://fixture.example.test/prefix/',
    createRequest() {
      const request = {
        responseText: '', readyState: 1, status: 200, headers: {}, aborts: 0,
        open(method, url, async) { Object.assign(this, { method, url, async }); },
        setRequestHeader(name, value) { this.headers[name] = value; },
        send() { callbacks.onSend?.(this); }, abort() { this.aborts++; this.onabort?.(); },
      };
      requests.push(request);
      return request;
    },
    onEvent(event) { events.push(plain(event)); callbacks.onEvent?.(transport, event); },
    onStatus(connected) { statuses.push(connected); callbacks.onStatus?.(transport, connected); },
    onSessionRevoked() { revoked++; },
    schedule(callback, milliseconds) { const id = ++timerID; timers.set(id, { callback, milliseconds }); return id; },
    cancelSchedule(id) { timers.delete(id); },
  });
  transport.start();
  return {
    transport, requests, events, statuses, timers, get revoked() { return revoked; },
    progress(chunk, request = requests.at(-1)) { request.responseText += chunk; request.onprogress?.(); },
    reconnect() {
      const entry = [...timers].find(([, timer]) => timer.milliseconds === 1_000);
      assert.ok(entry, 'The existing reconnect policy must schedule a first retry');
      timers.delete(entry[0]); entry[1].callback();
    },
    stop() { transport.stop(); assert.equal(timers.size, 0); },
  };
}

test('transport preserves CR, LF and split CRLF at every boundary', () => {
  for (const newline of ['\n', '\r', '\r\n']) {
    const wire = frame().replaceAll('\n', newline);
    for (let split = 0; split <= wire.length; split++) {
      const h = harness();
      try {
        h.progress(wire.slice(0, split)); h.progress(wire.slice(split));
        assert.deepEqual(h.events.map(event => event.id), ['devices:7'], `newline=${JSON.stringify(newline)} split=${split}`);
      } finally { h.stop(); }
    }
  }
});

test('oversized complete frame is rejected instead of delivered', () => {
  const h = harness();
  try {
    h.progress(frame('too-large', 'x'.repeat(limit)));
    assert.equal(h.events.length, 0);
    assert.equal(h.requests[0].aborts, 1);
    assert.equal(h.revoked, 0);
    h.reconnect();
    h.progress(frame('devices:8'));
    assert.deepEqual(h.events.map(event => event.id), ['devices:8']);
  } finally { h.stop(); }
});

test('oversized unfinished frame closes and cannot fabricate an event from its suffix', () => {
  const h = harness();
  try {
    h.progress('x'.repeat(limit + 1));
    const retired = h.requests[0];
    assert.equal(retired.aborts, 1);
    h.progress('\n\n' + frame('stale'), retired);
    retired.onerror?.(); retired.onload?.();
    assert.equal(h.events.length, 0);
    assert.equal([...h.timers.values()].filter(timer => timer.milliseconds === 1_000).length, 1);
    h.reconnect(); h.progress(frame('fresh'));
    assert.deepEqual(h.events.map(event => event.id), ['fresh']);
  } finally { h.stop(); }
});

test('frame budget is exact and applies to each frame rather than the progress chunk', () => {
  const h = harness();
  try {
    const padding = 'x'.repeat(limit - frame().length);
    assert.equal(frame('devices:7', padding).length, limit);
    h.progress(frame('devices:7', padding));
    assert.equal(h.events.length, 1);
    assert.equal(h.requests[0].aborts, 0);
    h.progress(frame().repeat(2_000));
    assert.equal(h.events.length, 2_001);
    assert.equal(h.requests[0].aborts, 0);
  } finally { h.stop(); }
});

test('cumulative XHR response rotates while preserving auth and the last acknowledged event', () => {
  const h = harness();
  try {
    h.progress(frame('devices:99'));
    const retired = h.requests[0];
    const comment = ':' + 'x'.repeat(1_000) + '\n\n';
    for (let count = 0; count < 1_200 && retired.aborts === 0; count++) h.progress(comment, retired);
    assert.equal(retired.aborts, 1, 'The cumulative XHR response must be retired at the response budget');
    assert.ok(retired.responseText.length < 1024 * 1024 + comment.length);
    assert.equal(h.revoked, 0);
    h.reconnect();
    const next = h.requests[1];
    assert.equal(next.headers['Last-Event-ID'], 'devices:99');
    assert.equal(next.headers.Authorization, 'Bearer fixture-token');
    assert.equal(next.url, 'https://fixture.example.test/prefix/v1/events');
    assert.equal(next.method, 'GET');
    h.progress(frame('retired'), retired);
    h.progress(frame('devices:100'), next);
    assert.deepEqual(h.events.map(event => event.id), ['devices:99', 'devices:100']);
  } finally { h.stop(); }
});

test('one large progress callback processes a bounded prefix before rotating', () => {
  const h = harness();
  try {
    const comment = ':' + 'x'.repeat(100) + '\n\n';
    h.progress(frame('before-cap') + comment.repeat(12_000) + frame('after-cap'));
    assert.equal(h.requests[0].aborts, 1);
    assert.deepEqual(h.events.map(event => event.id), ['before-cap']);
    h.reconnect();
    assert.equal(h.requests[1].headers['Last-Event-ID'], 'before-cap');
  } finally { h.stop(); }
});

test('stop during a callback suppresses remaining buffered events', () => {
  const h = harness({ onEvent(transport) { transport.stop(); } });
  try {
    h.progress(frame('first') + frame('cancelled'));
    assert.deepEqual(h.events.map(event => event.id), ['first']);
  } finally { h.stop(); }
});

test('stop from connected status suppresses the buffered event', () => {
  const h = harness({ onStatus(transport, connected) { if (connected) transport.stop(); } });
  try {
    h.progress(frame());
    assert.equal(h.events.length, 0);
    h.transport.start();
    assert.equal(h.requests[1].headers['Last-Event-ID'], undefined, 'Cancelled delivery cannot acknowledge an event');
  } finally { h.stop(); }
});

test('fragmented Unicode and incomplete EOF preserve existing event behavior', () => {
  const h = harness();
  try {
    const wire = frame('devices:7', 'Привет 👨‍👩‍👧‍👦 e\u0301');
    for (const unit of wire.split('')) h.progress(unit);
    assert.equal(h.events[0].data, JSON.stringify({ domain: 'devices', version: 7, extra: 'Привет 👨‍👩‍👧‍👦 e\u0301' }));
    h.progress(frame('unfinished').slice(0, -1));
    h.requests[0].onload?.();
    assert.equal(h.events.length, 1);
  } finally { h.stop(); }
});


test('legacy null resync survives framing and metadata projection', () => {
  const { customerRealtimeMetadata } = load('customerRealtimeCore');
  for (const reason of ['broker_error', 'initial', 'reconnect', 'subscriber_overflow', undefined]) {
    const h = harness();
    try {
      const data = JSON.stringify({ versions: null, reason });
      h.progress(`event: customer.resync\ndata: ${data}\n\n`);
      assert.deepEqual(h.events, [{ type: 'customer.resync', id: '', data }]);
      assert.deepEqual(plain(customerRealtimeMetadata('customer.resync', data)), { domains: [], reason: reason ?? 'resync' });
      assert.equal(h.statuses.at(-1), true);
      assert.equal(h.revoked, 0);
    } finally { h.stop(); }
  }
});

test('malformed and missing resync versions still reject', () => {
  for (const versions of [undefined, true, 1, 'null', {}]) {
    const h = harness();
    try {
      h.progress(`event: customer.resync\nid: invalid\ndata: ${JSON.stringify({ versions })}\n\n`);
      assert.equal(h.events.length, 0);
      h.requests[0].onerror(); h.reconnect();
      assert.equal(h.requests[1].headers['Last-Event-ID'], undefined);
    } finally { h.stop(); }
  }
});

for (const version of ['true', 'false', '0', '-1', '0.5', '1.5', '1e400', '"7"', 'null']) {
  test(`invalid change version ${version} cannot update cursor or dispatch a refresh`, () => {
    const h = harness();
    try {
      h.progress(`event: customer.change\nid: invalid-version\ndata: {"domain":"devices","version":${version}}\n\n`);
      assert.equal(h.events.length, 0);
      h.requests[0].onerror(); h.reconnect();
      assert.equal(h.requests[1].headers['Last-Event-ID'], undefined);
      assert.equal(h.revoked, 0);
    } finally { h.stop(); }
  });
}

test('all positive Go int64 versions remain valid invalidations', () => {
  const { customerRealtimeMetadata } = load('customerRealtimeCore');
  const h = harness();
  try {
    for (const version of ['1', '9007199254740991', '9007199254740992', '9007199254740993', '9223372036854775806', '9223372036854775807']) {
      const data = `{"domain":"devices","version":${version}}`;
      assert.deepEqual(plain(customerRealtimeMetadata('customer.change', data)), { domains: ['devices'], reason: '' });
      h.progress(`event: customer.change\nid: devices:${version}\ndata: ${data}\n\n`);
      assert.equal(h.events.at(-1).id, `devices:${version}`);
    }
    assert.equal(h.events.length, 6);
  } finally { h.stop(); }
});

test('revocation event cannot retire a replacement stream started by its callback', () => {
  let restarted = false;
  const h = harness({ onEvent(transport, event) {
    if (event.type === 'customer.session.revoked' && !restarted) {
      restarted = true; transport.stop(); transport.start();
    }
  } });
  try {
    h.progress('event: customer.session.revoked\ndata: {}\n\n');
    assert.equal(h.requests.length, 2); assert.equal(h.revoked, 0);
    h.progress(frame('replacement'));
    assert.deepEqual(h.events.map(event => event.type), ['customer.session.revoked', 'customer.change']);
  } finally { h.stop(); }
});

test('HTTP401 status callback cannot revoke a replacement stream', () => {
  let restarted = false;
  const h = harness({ onStatus(transport, connected) {
    if (!connected && !restarted) { restarted = true; transport.stop(); transport.start(); }
  } });
  try {
    h.requests[0].status = 401; h.requests[0].readyState = 2; h.requests[0].onreadystatechange();
    assert.equal(h.requests.length, 2); assert.equal(h.revoked, 0);
    h.progress(frame('replacement')); assert.equal(h.events[0].id, 'replacement');
  } finally { h.stop(); }
});

test('queued retired reconnect cannot replace the next stream or discard its backoff', () => {
  const h = harness();
  try {
    h.requests[0].onerror();
    const stale = [...h.timers.values()].find(timer => timer.milliseconds === 1_000).callback;
    h.stop(); h.transport.start(); h.progress(frame('current')); h.requests[1].onerror();
    stale(); assert.equal(h.requests.length, 2);
    h.reconnect(); assert.equal(h.requests.length, 3);
  } finally { h.stop(); }
});

test('synchronous injected rejection cannot arm a watchdog for a retired request', () => {
  const h = harness({ onSend(request) {
    request.status = 401; request.readyState = 2; request.onreadystatechange();
  } });
  try { assert.equal(h.revoked, 1); assert.equal(h.timers.size, 0); }
  finally { h.stop(); }
});
