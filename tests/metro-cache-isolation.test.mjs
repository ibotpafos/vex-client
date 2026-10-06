import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(import.meta.dirname, "..");
const metroConfig = fs.readFileSync(path.join(root, "metro.config.js"), "utf8");
const gitignore = fs.readFileSync(path.join(root, ".gitignore"), "utf8");

test("Metro uses a checkout-local cache without Watchman", () => {
  assert.match(metroConfig, /config\.resolver\.useWatchman\s*=\s*false/);
  assert.match(metroConfig, /config\.fileMapCacheDirectory\s*=\s*__dirname\s*\+\s*["']\/.metro-file-map-cache["']/);
  assert.match(gitignore, /^\.metro-file-map-cache\/$/m);
});
