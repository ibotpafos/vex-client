import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  createOtaCompletionTarget,
  parseOtaCompletionTarget,
  wasOtaCompletionApplied,
} from "../src/updates/otaCompletion.ts";

const runtime = "1.0.59";
const current = {
  updateId: "new-update",
  runtimeVersion: runtime,
  isEmbeddedLaunch: false,
  isEmergencyLaunch: false,
};

test("only the exact downloaded update earns an Updated confirmation", () => {
  const target = createOtaCompletionTarget(
    { type: "new", updateId: "new-update" },
    runtime,
  );
  assert.deepEqual(target, {
    type: "new",
    updateId: "new-update",
    runtimeVersion: runtime,
  });
  assert.equal(wasOtaCompletionApplied(target, current), true);
  assert.equal(
    wasOtaCompletionApplied(target, { ...current, updateId: "old-update" }),
    false,
  );
  assert.equal(
    wasOtaCompletionApplied(target, { ...current, runtimeVersion: "1.0.60" }),
    false,
  );
  assert.equal(
    wasOtaCompletionApplied(target, { ...current, isEmbeddedLaunch: true }),
    false,
  );
  assert.equal(
    wasOtaCompletionApplied(target, { ...current, isEmergencyLaunch: true }),
    false,
  );
});

test("rollback confirmation requires a non-emergency embedded launch", () => {
  const target = createOtaCompletionTarget({ type: "rollback" }, runtime);
  assert.deepEqual(target, { type: "rollback", runtimeVersion: runtime });
  assert.equal(
    wasOtaCompletionApplied(target, { ...current, isEmbeddedLaunch: true }),
    true,
  );
  assert.equal(wasOtaCompletionApplied(target, current), false);
  assert.equal(
    wasOtaCompletionApplied(target, {
      ...current,
      isEmbeddedLaunch: true,
      isEmergencyLaunch: true,
    }),
    false,
  );
});

test("stale or malformed markers never claim success", () => {
  assert.equal(createOtaCompletionTarget({ type: "new" }, runtime), null);
  assert.equal(
    createOtaCompletionTarget({ type: "new", updateId: "id" }, ""),
    null,
  );
  assert.equal(parseOtaCompletionTarget(null), null);
  assert.equal(parseOtaCompletionTarget("{bad"), null);
  assert.equal(
    parseOtaCompletionTarget(
      JSON.stringify({
        type: "new",
        updateId: "id",
        runtimeVersion: runtime,
        extra: "ignored",
      }),
    )?.updateId,
    "id",
  );
  assert.equal(
    parseOtaCompletionTarget(
      JSON.stringify({ type: "new", runtimeVersion: runtime }),
    ),
    null,
  );
  assert.equal(
    parseOtaCompletionTarget(
      JSON.stringify({ type: "rollback", runtimeVersion: "" }),
    ),
    null,
  );
});

test("OTA overlay handles rollback directives and confirms only after reload", () => {
  const overlay = readFileSync(
    new URL("../src/components/ota-update-overlay.tsx", import.meta.url),
    "utf8",
  );
  assert.match(overlay, /check\.isRollBackToEmbedded/);
  assert.match(overlay, /wasOtaCompletionApplied/);
  assert.match(overlay, /Обновлено/);
  assert.match(overlay, /downloadProgress/);
  // An absolutely positioned native Host otherwise has no intrinsic RN height:
  // OTA can download/apply correctly while every progress/ready notice is hidden.
  assert.match(overlay, /<Host[^>]*matchContents=\{\{ vertical: true \}\}/);
});

test("manual OTA action delegates to the one shared expo-updates controller", () => {
  const center = readFileSync(
    new URL("../src/components/update-center.tsx", import.meta.url),
    "utf8",
  );
  const overlay = readFileSync(
    new URL("../src/components/ota-update-overlay.tsx", import.meta.url),
    "utf8",
  );
  assert.match(center, /useOtaPresentation/);
  assert.match(center, /await ota\.checkForUpdate\(true\)/);
  assert.match(center, /await ota\.reload\(\)/);
  assert.match(center, /otaActionRunningRef\.current/);
  assert.doesNotMatch(center, /Updates\.checkForUpdateAsync/);
  assert.doesNotMatch(center, /Updates\.fetchUpdateAsync/);
  assert.match(overlay, /await Updates\.checkForUpdateAsync\(\)/);
  assert.match(overlay, /await Updates\.fetchUpdateAsync\(\)/);
  assert.match(overlay, /pendingOtaCompletionKey/);
  assert.match(overlay, /createOtaCompletionTarget/);
  assert.match(overlay, /wasOtaCompletionApplied/);
});
