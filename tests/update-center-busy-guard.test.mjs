import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/components/update-center.tsx", "utf8");

assert.match(
  source,
  /const isCheckingForUpdates =\s*updateQuery\.isFetching \|\| isOtaActionBusy \|\| Boolean\(ota\?\.isBusy\);/,
  "one busy value must include an in-flight metadata query",
);
assert.match(
  source,
  /const isPrimaryBusy =\s*isOtaActionBusy \|\|\s*Boolean\(ota\?\.isBusy\) \|\|\s*\(updateQuery\.isFetching && !otaReadyWithoutMetadata\);/,
  "a ready signed OTA must remain actionable while metadata is refreshing",
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
assert.match(
  source,
  /disabled=\{isCheckingForUpdates\}/,
  "the secondary action must share the same busy guard",
);
const actions = source.slice(
  source.indexOf('<View style={styles.actions}>'),
  source.indexOf("<Text style={styles.footnote}>"),
);
assert.equal(
  (actions.match(/isCheckingForUpdates\s*\?\s*"Проверяем"/g) || []).length,
  1,
  "the secondary action must expose query activity",
);
assert.equal(
  (actions.match(/isPrimaryBusy\s*\?\s*"Проверяем"/g) || []).length,
  1,
  "the primary action must expose only blocking activity",
);
const derive = ({ queryFetching, otaReady, otaBusy, localOtaBusy, nativeRequired }) => {
  const ready = otaReady && !nativeRequired;
  const checking = queryFetching || otaBusy || localOtaBusy;
  const primaryBusy = otaBusy || localOtaBusy || (queryFetching && !ready);
  return { checking, primaryBusy, primaryLabel: primaryBusy ? "Проверяем" : ready ? "Применить безопасно" : "Проверить снова" };
};
assert.deepEqual(
  derive({ queryFetching: true, otaReady: false, otaBusy: false, localOtaBusy: false, nativeRequired: false }),
  { checking: true, primaryBusy: true, primaryLabel: "Проверяем" },
  "metadata refresh without a ready OTA blocks both actions",
);
assert.deepEqual(
  derive({ queryFetching: true, otaReady: true, otaBusy: false, localOtaBusy: false, nativeRequired: false }),
  { checking: true, primaryBusy: false, primaryLabel: "Применить безопасно" },
  "a signed ready OTA remains safe to apply while metadata refreshes",
);
assert.equal(
  derive({ queryFetching: true, otaReady: true, otaBusy: true, localOtaBusy: false, nativeRequired: false }).primaryBusy,
  true,
  "an active OTA operation still blocks reload",
);
assert.equal(
  derive({ queryFetching: true, otaReady: true, otaBusy: false, localOtaBusy: false, nativeRequired: true }).primaryLabel,
  "Проверяем",
  "native-required priority prevents ready-OTA apply during metadata refresh",
);

console.log(
  "UPDATE_CENTER_BUSY_GUARD=PASS: metadata blocks duplicate checks without blocking a signed ready OTA",
);
