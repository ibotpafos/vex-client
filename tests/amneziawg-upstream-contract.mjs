#!/usr/bin/env node
import assert from 'node:assert/strict';
import { existsSync, readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const awg31GoRef = 'b5928efb6ca19f0153958460c3d141f04abc5c2e';
const awg31GoVersion = 'v3.1.20260828';
const awg31ToolsRef = 'ee0f0a9aa34ff0a0da4b3433b9512781cfe02843';
const awg31ToolsVersion = 'v3.1.20260812';
const awg31AndroidRef = '5c16489e2cd9ed3a0a7a27c7445bba5238132f86';
const iosGoVersion = awg31GoVersion;
const read = (relative) => readFileSync(join(root, relative), 'utf8');

const android = read('scripts/bootstrap_amneziawg_android.sh');
assert.ok(android.includes(`android_ref="${awg31AndroidRef}"`));
assert.ok(android.includes(`go_ref="${awg31GoRef}"`));
assert.ok(!android.includes('AMNEZIAWG_GO_REF'));
assert.ok(!android.includes('amneziawg-go-fast-rekey.patch'));

const androidLocalGoPatch = read('patches/amnezia/amneziawg-android-macos-local-go.patch');
assert.ok(androidLocalGoPatch.includes('+replace github.com/amnezia-vpn/amneziawg-go/v3 => ../../../../amneziawg-go'));
assert.ok(!androidLocalGoPatch.includes('+replace github.com/amnezia-vpn/amneziawg-go =>'));
assert.ok(android.includes('go list -m -json github.com/amnezia-vpn/amneziawg-go/v3'));
assert.ok(android.includes('migrate_legacy_local_go_patch'));

const androidToolchainPatch = read('patches/amnezia/amneziawg-android-go125-toolchain.patch');
assert.ok(android.includes('amneziawg-android-go125-toolchain.patch'));
assert.ok(androidToolchainPatch.includes('+GO_VERSION := 1.25.14'));
// Official go.dev release checksums; preserve the existing patched runtime build.
for (const checksum of [
  'b09087a67d5792a8b0fcbf74212d62560c94ac8a8fd750ff920d8cb5f1e20118',
  '5b26c0b6f308240fca2614fb02f622cfcc8c0cc3b69c78bba4845489a4590259',
  'a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712',
]) assert.ok(androidToolchainPatch.includes(checksum));
assert.ok(androidLocalGoPatch.includes('goruntime-boottime-over-monotonic.diff'));

const routingToolchainPatch = read('patches/amnezia/amneziawg-android-routing-go126-toolchain.patch');
assert.ok(routingToolchainPatch.includes('+GO_VERSION := 1.26.10'));
for (const checksum of [
  'e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da',
  '0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3',
  'ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5',
]) assert.ok(routingToolchainPatch.includes(checksum));

// Execute only the actual local migration fragment on tiny isolated Makefiles.
// Never invoke SDK bootstrap, network fetches or a native compiler in this test.
const securityUpdate = read('patches/amnezia/amneziawg-android-routing-go126-security-update.patch');
const snapshot = (patch, side) => patch.split('\n')
  .filter(line => line && !/^(---|\+\+\+|@@)/.test(line) && (line[0] === ' ' || line[0] === side))
  .map(line => line.slice(1)).join('\n') + '\n';
const baseMakefile = snapshot(routingToolchainPatch, '-');
const currentMakefile = snapshot(routingToolchainPatch, '+');
const previousMakefile = snapshot(securityUpdate, '-');
const migrationFragment = android.slice(android.indexOf('toolchain_patch='), android.indexOf('build_patch='));
assert.ok(migrationFragment.includes('toolchain_security_update='));
const fixture = mkdtempSync(join(tmpdir(), 'vex-toolchain-migration-'));
try {
  const checkout = join(fixture, 'amneziawg-android');
  const makefile = join(checkout, 'tunnel/tools/libwg-go/Makefile');
  mkdirSync(dirname(makefile), { recursive: true });
  const prefix = '# unrelated upstream context\n'.repeat(20);
  for (const initial of [baseMakefile, previousMakefile, currentMakefile]) {
    writeFileSync(makefile, prefix + initial);
    for (let pass = 0; pass < 2; pass++) {
      const result = spawnSync('bash', ['-euc', migrationFragment + '\ngit -C "$external_dir/amneziawg-android" apply "$toolchain_patch"'], {
        env: { ...process.env, root_dir: root, external_dir: fixture }, encoding: 'utf8',
      });
      assert.equal(result.status, 0, `initial=${initial === baseMakefile ? "base" : initial === previousMakefile ? "previous" : "current"}, pass=${pass}: ${result.stderr}`);
      assert.equal(readFileSync(makefile, 'utf8'), prefix + currentMakefile);
    }
  }
  const unexpected = prefix + previousMakefile.replace('GO_HASH_linux-amd64 := ', 'GO_HASH_linux-amd64 := unexpected-');
  writeFileSync(makefile, unexpected);
  const rejected = spawnSync('bash', ['-euc', migrationFragment + '\ngit -C "$external_dir/amneziawg-android" apply "$toolchain_patch"'], {
    env: { ...process.env, root_dir: root, external_dir: fixture }, encoding: 'utf8',
  });
  assert.notEqual(rejected.status, 0);
  assert.equal(readFileSync(makefile, 'utf8'), unexpected);
} finally { rmSync(fixture, { recursive: true, force: true }); }


const macos = read('scripts/bootstrap_amneziawg_macos.sh');
assert.ok(macos.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macos.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(!macos.includes('AMNEZIAWG_GO_REF'));

const macosBuild = read('scripts/build_amneziawg_macos_binaries.sh');
assert.ok(macosBuild.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macosBuild.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(macosBuild.includes('AmneziaWG 3.1'));
assert.ok(macosBuild.includes(`awg ${awg31ToolsVersion}`));
assert.ok(macosBuild.includes(`AmneziaWG 3.1 ${awg31GoVersion}`));
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
