const assert = require("node:assert/strict");
const http = require("node:http");
const { once } = require("node:events");
const { createRequire } = require("node:module");
const { gzipSync } = require("node:zlib");
const test = require("node:test");

test("installed HTTP dependencies preserve parsing, error and abort contracts", { timeout: 10000 }, async (t) => {
  const express = require("express");
  const bodyParser = require("body-parser");
  const { Pool } = require("undici");
  const app = express();
  app.use(bodyParser.json({ limit: "4kb" }));
  app.use(bodyParser.urlencoded({ extended: true, limit: "4kb" }));
  app.post("/echo", (request, response) => response.status(201).json(request.body));
  let acceptStall;
  const stalled = new Promise((resolve) => { acceptStall = resolve; });
  app.get("/stall", () => acceptStall());
  app.use((error, _request, response, _next) => {
    response.status(error.status || 500).json({ code: error.type });
  });

  // Owned loopback only: no app/VPN server, device, credential or external host.
  const server = http.createServer(app);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const pool = new Pool(`http://127.0.0.1:${server.address().port}`, { connections: 2 });
  t.after(async () => {
    await pool.destroy();
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });

  const value = { fixture: [1, 2], nested: { enabled: true } };
  for (const compressed of [false, true]) {
    const response = await pool.request({
      method: "POST", path: "/echo",
      headers: { "content-type": "application/json", ...(compressed ? { "content-encoding": "gzip" } : {}) },
      body: compressed ? gzipSync(JSON.stringify(value)) : JSON.stringify(value),
    });
    assert.equal(response.statusCode, 201);
    assert.deepEqual(await response.body.json(), value);
  }
  const form = await pool.request({
    method: "POST", path: "/echo", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "nested[value]=fixture",
  });
  assert.equal(form.statusCode, 201);
  assert.deepEqual(await form.body.json(), { nested: { value: "fixture" } });

  for (const [body, status, code] of [
    ["{", 400, "entity.parse.failed"],
    [JSON.stringify({ large: "x".repeat(5000) }), 413, "entity.too.large"],
  ]) {
    const response = await pool.request({ method: "POST", path: "/echo", headers: { "content-type": "application/json" }, body });
    assert.equal(response.statusCode, status);
    assert.deepEqual(await response.body.json(), { code });
  }

  const controller = new AbortController();
  const pending = pool.request({ method: "GET", path: "/stall", signal: controller.signal });
  await stalled;
  controller.abort();
  await assert.rejects(pending, (error) => error.name === "AbortError" || error.code === "UND_ERR_ABORTED");
});

test("installed Ajv resolves relative references through its URI parser", () => {
  // ESLint also retains Ajv 6, which uses a different URI implementation.
  // Exercise the SDK's actual Ajv 8 owner of the updated fast-uri dependency.
  const sdkRequire = createRequire(require.resolve("@modelcontextprotocol/sdk/server/mcp.js"));
  const Ajv = sdkRequire("ajv");
  const ajvRequire = createRequire(sdkRequire.resolve("ajv"));
  assert.equal(ajvRequire.resolve("fast-uri"), require.resolve("fast-uri"));
  const ajv = new Ajv({ strict: true, allErrors: true });
  ajv.addSchema({
    $id: "https://fixture.invalid/schemas/definitions/item",
    type: "object", required: ["id"], additionalProperties: false,
    properties: { id: { type: "integer", minimum: 1 } },
  });
  const validate = ajv.compile({
    $id: "https://fixture.invalid/schemas/payload",
    type: "object", required: ["item"], additionalProperties: false,
    properties: { item: { $ref: "definitions/item" } },
  });
  assert.equal(validate({ item: { id: 1 } }), true);
  assert.equal(validate({ item: { id: 0 } }), false);
  assert.equal(validate.errors[0].instancePath, "/item/id");
  assert.equal(validate.errors[0].keyword, "minimum");
});

test("installed MCP SDK keeps Zod 4 and legacy schema interoperability", { timeout: 10000 }, async (t) => {
  const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
  const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
  const { InMemoryTransport } = require("@modelcontextprotocol/sdk/inMemory.js");
  const z4 = require("zod");
  const z3 = require("zod/v3");
  const server = new McpServer({ name: "dependency-fixture", version: "1.0.0" });
  const client = new Client({ name: "dependency-fixture-client", version: "1.0.0" });
  let calls = 0;
  for (const [name, z] of [["fixture_v4", z4], ["fixture_legacy", z3]]) {
    server.registerTool(name, { inputSchema: { value: z.string().max(32) } }, async ({ value }) => {
      calls += 1;
      return { content: [{ type: "text", text: value }] };
    });
  }
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  t.after(async () => {
    const results = await Promise.allSettled([client.close(), server.close()]);
    for (const result of results) assert.equal(result.status, "fulfilled");
  });
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map((tool) => tool.name).sort(), ["fixture_legacy", "fixture_v4"]);
  for (const name of ["fixture_v4", "fixture_legacy"]) {
    const response = await client.callTool({ name, arguments: { value: "fixture" } });
    assert.deepEqual(response.content, [{ type: "text", text: "fixture" }]);
    try {
      const invalid = await client.callTool({ name, arguments: { value: "x".repeat(33) } });
      assert.equal(invalid.isError, true);
    } catch (error) {
      assert.equal(error.code, -32602);
    }
  }
  assert.equal(calls, 2, "invalid arguments must not reach either callback");
});
