#!/usr/bin/env node
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const awg31GoRef = 'b5928efb6ca19f0153958460c3d141f04abc5c2e';
const awg31GoVersion = 'v3.1.20260828';
const awg31ToolsRef = 'ee0f0a9aa34ff0a0da4b3433b9512781cfe02843';
const awg31AndroidRef = '5c16489e2cd9ed3a0a7a27c7445bba5238132f86';
const iosGoVersion = 'v3.0.20260805';
const read = (relative) => readFileSync(join(root, relative), 'utf8');

const android = read('scripts/bootstrap_amneziawg_android.sh');
assert.ok(android.includes(`android_ref="${awg31AndroidRef}"`));
assert.ok(android.includes(`go_ref="${awg31GoRef}"`));
assert.ok(!android.includes('AMNEZIAWG_GO_REF'));
assert.ok(!android.includes('amneziawg-go-fast-rekey.patch'));

const macos = read('scripts/bootstrap_amneziawg_macos.sh');
assert.ok(macos.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macos.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(!macos.includes('AMNEZIAWG_GO_REF'));

const macosBuild = read('scripts/build_amneziawg_macos_binaries.sh');
assert.ok(macosBuild.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macosBuild.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(macosBuild.includes('AmneziaWG 3.1'));
assert.ok(!macos.includes('amneziawg-go-fast-rekey.patch'));
assert.ok(!existsSync(join(root, 'patches/amnezia/amneziawg-go-fast-rekey.patch')));

const ios = read('scripts/bootstrap_amneziawg_ios.sh');
assert.ok(ios.includes('apple_ref="4bafa5958a80c8be76bd89d1e02984c6307769d2"'));
assert.ok(!ios.includes('${AMNEZIAWG_APPLE_REF:-'));
assert.ok(ios.includes(`go_version="${iosGoVersion}"`));
assert.ok(ios.includes('go mod edit'));
assert.ok(ios.includes('verify_amneziawg_keepalive_upstream.sh'));

const verifier = read('scripts/verify_amneziawg_keepalive_upstream.sh');
assert.ok(verifier.includes('isKeepalive'));
assert.ok(verifier.includes('elem.packet[0] == 0'));
assert.ok(verifier.includes('RekeyTimeout'));
assert.ok(verifier.includes('time.Second * 5'));
assert.ok(verifier.includes('diff --quiet'));

const packageJson = JSON.parse(read('package.json'));
assert.equal(packageJson.scripts['test:awg-upstream'], 'node tests/amneziawg-upstream-contract.mjs');
assert.ok(packageJson.scripts.check.includes('npm run test:awg-upstream'));

console.log('AmneziaWG upstream contract OK');
