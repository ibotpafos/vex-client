import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";

const helperSource = readFileSync("src/updates/otaPresentation.ts", "utf8");
const helperJs = ts.transpileModule(helperSource, {
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText;
const helperExports = {};
new Function("exports", helperJs)(helperExports);
const {
  canRunOtaCheck,
  reloadOtaSafely,
  shouldShowOtaHeaderAction,
  shouldShowOtaOverlay,
} = helperExports;

test("ready OTA uses header action instead of content-covering overlay", () => {
  assert.equal(shouldShowOtaOverlay("ready"), false);
  assert.equal(shouldShowOtaHeaderAction("ready"), true);
  assert.equal(shouldShowOtaOverlay("idle"), false);
  assert.equal(shouldShowOtaOverlay("checking"), false);
});

test("transient OTA states retain progress, completion and error notices", () => {
  for (const status of [
    "downloading",
    "restarting",
    "updated",
    "rolled_back",
    "error",
  ])
    assert.equal(shouldShowOtaOverlay(status), true);
});

test("Later blocks passive checks but a forced manual retry is allowed", () => {
  const input = {
    dismissed: true,
    running: false,
    nativeBusy: false,
    status: "error",
  };
  assert.equal(canRunOtaCheck({ ...input, force: false }), false);
  assert.equal(canRunOtaCheck({ ...input, force: true }), true);
});

test("active VPN leaves update ready with a truthful blocked message", async () => {
  const messages = [];
  const reloaded = await reloadOtaSafely({
    getAppState: () => "active",
    canApply: () => false,
    getVpnStatus: async () => ({ leakProtection: "disabled" }),
    isReady: () => true,
    lock: { current: false },
    onBlocked: (message) => messages.push(message),
    performReload: async () => true,
  });
  assert.equal(reloaded, false);
  assert.deepEqual(messages, [
    "Обновление ждёт отключения VPN, чтобы не прервать соединение.",
  ]);
});

test("concurrent Apply attempts invoke reload once", async () => {
  let release;
  let calls = 0;
  const lock = { current: false };
  const input = {
    getAppState: () => "active",
    canApply: () => true,
    getVpnStatus: async () => ({}),
    isReady: () => true,
    lock,
    onBlocked: () => undefined,
    performReload: async () => {
      calls++;
      await new Promise((resolve) => {
        release = resolve;
      });
      return true;
    },
  };
  const first = reloadOtaSafely(input);
  await Promise.resolve();
  const second = reloadOtaSafely(input);
  assert.equal(await second, false);
  assert.equal(typeof release, "function");
  release();
  assert.equal(await first, true);
  assert.equal(calls, 1);
});

test("center consumes the shared OTA controller and makes a metadata-free ready update actionable", () => {
  const source = readFileSync("src/components/update-center.tsx", "utf8");
  assert.match(source, /const ota = useOtaPresentation\(\);/);
  assert.match(source, /otaReadyWithoutMetadata/);
  assert.match(source, /await ota\.checkForUpdate\(true\)/);
  assert.match(source, /await ota\.reload\(\)/);
  assert.doesNotMatch(
    source,
    /const check = await Updates\.checkForUpdateAsync\(\)/,
  );
});

test("header icon is hidden unless a native release or unapplied OTA exists", () => {
  const source = readFileSync("src/components/update-center.tsx", "utf8");
  assert.match(source, /shouldOfferAppUpdate\(update, buildNumber\)/);
  assert.match(source, /const hasUnappliedOta = ota\?\.status === "downloading" \|\| ota\?\.status === "ready";/);
  assert.match(source, /if \(!hasNativeUpdate && !hasUnappliedOta\) \{\s+return null;/);
  assert.match(source, /<VexPressable/);
  assert.match(source, /<Download color="#EAF7F8" size=\{25\} strokeWidth=\{2\.15\}/);
  assert.doesNotMatch(source, /headerBadge/);
  assert.match(source, /await Promise\.all\(\[/);
  assert.match(source, /ota\?\.isSupported \? ota\.checkForUpdate\(true\) : Promise\.resolve\(\)/);
});

test("background transition during a deferred VPN read forbids reload", async () => {
  let appState = "active";
  let resolveVpn;
  let reloads = 0;
  const pending = reloadOtaSafely({
    getAppState: () => appState,
    canApply: () => true,
    getVpnStatus: () =>
      new Promise((resolve) => {
        resolveVpn = resolve;
      }),
    isReady: () => true,
    lock: { current: false },
    onBlocked: () => undefined,
    performReload: async () => {
      reloads++;
      return true;
    },
  });
  appState = "background";
  resolveVpn({ leakProtection: "disabled" });
  assert.equal(await pending, false);
  assert.equal(reloads, 0);
});
