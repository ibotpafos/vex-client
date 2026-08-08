#!/usr/bin/env node
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const fixedGoRef = '08d68cdae27762c3e07f36bbb12d2bad32f81926';
const fixedGoVersion = 'v3.0.20260805';
const read = (relative) => readFileSync(join(root, relative), 'utf8');

const android = read('scripts/bootstrap_amneziawg_android.sh');
assert.ok(android.includes(`go_ref="${fixedGoRef}"`));
assert.ok(!android.includes('AMNEZIAWG_GO_REF'));
assert.ok(!android.includes('amneziawg-go-fast-rekey.patch'));

const macos = read('scripts/bootstrap_amneziawg_macos.sh');
assert.ok(macos.includes(`go_ref="${fixedGoRef}"`));
assert.ok(!macos.includes('AMNEZIAWG_GO_REF'));
assert.ok(!macos.includes('amneziawg-go-fast-rekey.patch'));
assert.ok(!existsSync(join(root, 'patches/amnezia/amneziawg-go-fast-rekey.patch')));

const ios = read('scripts/bootstrap_amneziawg_ios.sh');
assert.ok(ios.includes('apple_ref="4bafa5958a80c8be76bd89d1e02984c6307769d2"'));
assert.ok(!ios.includes('${AMNEZIAWG_APPLE_REF:-'));
assert.ok(ios.includes(`go_version="${fixedGoVersion}"`));
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
