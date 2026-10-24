const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const lock = JSON.parse(readFileSync(path.join(root, "package-lock.json"), "utf8"));

test("native config plugins load and register with the installed Expo SDK", () => {
  const withNativeConfig = require("../modules/vex-vpn/plugin/withVexNativeConfig.js");
  const withVpnIos = require("../modules/vex-vpn/plugin/withVexVpnIos.js");
  const config = withVpnIos(withNativeConfig({ name: "Plugin load fixture", slug: "plugin-load-fixture" }));
  assert.equal(typeof config.mods.android.manifest, "function");
  assert.equal(typeof config.mods.ios.entitlements, "function");
});

test("all MCP, address-parser and source-map copies exclude reviewed vulnerable ranges", () => {
  for (const [name, minimum] of Object.entries({
    "@modelcontextprotocol/sdk": [1, 32, 0],
    "ip-address": [10, 7, 4],
    "source-map-js": [1, 2, 2],
  })) {
    const entries = Object.entries(lock.packages).filter(([key]) => key.endsWith(`/node_modules/${name}`) || key === `node_modules/${name}`);
    assert.ok(entries.length, `${name}: dependency must be accounted for`);
    for (const [key, entry] of entries) {
      assert.match(entry.version, /^\d+\.\d+\.\d+$/, `${key}: review prereleases separately`);
      const [major, minor, patch] = entry.version.split(".").map(Number);
      assert.ok(major === minimum[0] && (minor > minimum[1] || (minor === minimum[1] && patch >= minimum[2])), `${key}: ${entry.version} is below the reviewed patched line`);
    }
  }
});

test("OTA publisher retains the compatible pinned protocol after removing unused EOAS3", () => {
  const manifest = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
  assert.equal(manifest.devDependencies.eoas, undefined);
  const publisher = readFileSync(path.join(root, "scripts/publish_ota_update.sh"), "utf8");
  assert.match(publisher, /ota_cli=\(npm exec --yes --package=eoas@2\.3\.23 -- eoas\)/);
});
