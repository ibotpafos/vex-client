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
assert.match(content, /otaUpdateAvailable \? "Доступно обновление" : assessment\.title/);
assert.match(content, /Обновление установится без переустановки приложения/);
const actions = content.slice(content.indexOf('<View style={styles.actions}>'));
assert.equal((actions.match(/<Pressable/g) || []).length, 1);
assert.match(actions, /"Проверить обновления"/);
assert.match(actions, /"Обновить"/);
assert.match(actions, /"Применить"/);
assert.match(actions, /"Повторить проверку"/);
assert.match(content, /const needsNativeRecovery =\s*assessment\.updateAvailable/);
assert.match(content, /if \(needsNativeRecovery\) \{\s*await checkForUpdates\(\);/);
console.log("UPDATE_CENTER_CLEANUP=PASS: user-facing update state only, single action, no idle header icon");

// Copy stays actionable without changing the update controller's safety policy.
const android = readFileSync("src/components/android-update-overlay.tsx", "utf8");
const ios = readFileSync("src/components/ios-update-overlay.tsx", "utf8");
const otaOverlay = readFileSync("src/components/ota-update-overlay.tsx", "utf8");
assert.match(source, /Новая сборка VEX/);
assert.match(source, /Обновление скачано\. Применим его безопасно, когда VPN можно отключить\./);
assert.match(source, /Другая подпись: автоустановка недоступна\./);
assert.match(android, /Другая подпись: скачайте APK и установите отдельно\. Войдите и проверьте доступ, затем удалите старый VEX\./);
assert.match(android, /проверим контрольную сумму и подпись/);
assert.match(android, /Если Android запросил разрешение, включите установку для VEX и вернитесь\./);
assert.match(android, /Если она не открылась или отменена, нажмите «Продолжить установку»\./);
for (const overlay of [android, ios]) {
  assert.match(overlay, /Установите стабильную версию: текущая сборка не поддерживается\./);
  assert.ok(overlay.includes("update.latestVersion") && overlay.includes("update.latestBuild"));
}
assert.match(ios, /Версия не поддерживается\. Обновите VEX, чтобы продолжить работу\./);
assert.match(otaOverlay, /Безопасная встроенная версия запущена и готова к работе\./);
assert.match(otaOverlay, /Перезапускаем VEX без переустановки\./);
assert.ok(otaOverlay.includes("Скачиваем исправления: ${ota.progress}%."));
console.log("UPDATE_COPY=PASS: concise Russian with migration, installer, compatibility, VPN safety and progress intact");
