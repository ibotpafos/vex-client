import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { shouldOfferAppUpdate } from "../src/api/updatePreflight.ts";

const source = readFileSync("src/components/update-center.tsx", "utf8");
const content = source.slice(
  source.indexOf("function MobileUpdateCenterContent("),
  source.indexOf("function StatusHero("),
);

assert.match(source, /shouldOfferAppUpdate\(update, buildNumber\)/);
assert.equal(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1006775 }, 1006775), false, "same build cannot expose the header");
assert.equal(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1006774 }, 1006775), false, "older build cannot expose the header");
assert.equal(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1006776 }, 1006775), true, "newer build remains actionable");
assert.equal(shouldOfferAppUpdate({ updateAvailable: true, currentBuildBlocked: true, latestBuild: 1006774 }, 1006775), true, "blocked build remains actionable");
assert.match(source, /const hasUnappliedOta = ota\?\.status === "downloading" \|\| ota\?\.status === "ready";/);
assert.match(source, /if \(!hasNativeUpdate && !hasUnappliedOta\) \{\s+return null;/);
assert.match(source, /<VexPressable/);
assert.match(source, /Download color="#EAF7F8" size=\{25\} strokeWidth=\{2\.15\}/);
assert.doesNotMatch(source, /headerBadge|headerButtonDanger|headerButtonHighlighted/);
assert.match(content, /label="Ваша версия"/);
assert.match(content, /assessment\.updateAvailable \? \(\s*<InfoRow\s*label="Новая версия"/);
assert.match(content, /assessment\.updateAvailable && update\?\.changelog/);
assert.doesNotMatch(content, /Канал APK|Подпись APK|Минимальная сборка|Rollout|runtime \$\{Updates\.runtimeVersion\}/);
const actions = content.slice(content.indexOf('<View style={styles.actions}>'));
assert.equal((actions.match(/<Pressable/g) || []).length, 1);
assert.match(actions, /"Проверить обновления"/);
assert.match(actions, /"Обновить"/);
assert.match(actions, /"Применить"/);
assert.match(actions, /"Повторить проверку"/);
assert.match(content, /const needsNativeRecovery =\s*assessment\.updateAvailable/);
assert.match(content, /if \(needsNativeRecovery\) \{\s*await checkForUpdates\(\);/);
console.log("UPDATE_CENTER_CLEANUP=PASS: user-facing update state only, single action, no idle header icon");
