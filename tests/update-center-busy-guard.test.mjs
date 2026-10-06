import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/components/update-center.tsx", "utf8");

assert.match(
  source,
  /const isPrimaryBusy =\s*isOtaActionBusy \|\|\s*Boolean\(ota\?\.isBusy\) \|\|\s*\(updateQuery\.isFetching && !otaReadyWithoutMetadata\);/,
  "the one primary action must block duplicate work while metadata is fetching",
);
assert.match(
  source,
  /const primaryDisabled =\s*isPrimaryBusy \|\|/,
  "the primary action must not start a second check while metadata is fetching",
);
assert.match(
  source,
  /otaActionRunningRef\.current \|\| ota\?\.isBusy \|\| updateQuery\.isFetching/,
  "manual refresh must not refetch while the query is already in flight",
);
const actions = source.slice(
  source.indexOf('<View style={styles.actions}>'),
  source.indexOf("</ScrollView>"),
);
assert.equal(
  (actions.match(/<Pressable/g) || []).length,
  1,
  "the update center must not render duplicate check/install actions",
);
assert.match(actions, /isPrimaryBusy\s*\?\s*"Проверяем"/);
assert.match(actions, /"Проверить обновления"/);
assert.match(actions, /"Обновить"/);
assert.match(actions, /"Применить"/);
assert.match(actions, /"Повторить проверку"/);
assert.match(source, /if \(needsNativeRecovery\) \{\s*await checkForUpdates\(\);/, "a rejected native payload keeps a single safe refresh action");
const derive = ({ queryFetching, otaReady, otaBusy, localOtaBusy, nativeRequired }) => {
  const ready = otaReady && !nativeRequired;
  const primaryBusy = otaBusy || localOtaBusy || (queryFetching && !ready);
  return {
    primaryBusy,
    primaryLabel: primaryBusy ? "Проверяем" : ready ? "Применить" : "Проверить обновления",
  };
};
assert.deepEqual(
  derive({ queryFetching: true, otaReady: false, otaBusy: false, localOtaBusy: false, nativeRequired: false }),
  { primaryBusy: true, primaryLabel: "Проверяем" },
  "metadata refresh without a ready OTA blocks the only action",
);
assert.deepEqual(
  derive({ queryFetching: true, otaReady: true, otaBusy: false, localOtaBusy: false, nativeRequired: false }),
  { primaryBusy: false, primaryLabel: "Применить" },
  "a signed ready OTA remains safe to apply while metadata refreshes",
);
assert.equal(
  derive({ queryFetching: true, otaReady: true, otaBusy: true, localOtaBusy: false, nativeRequired: false }).primaryBusy,
  true,
  "an active OTA operation still blocks reload",
);
console.log("UPDATE_CENTER_BUSY_GUARD=PASS: one guarded action prevents duplicate checks while keeping ready OTA apply available");
