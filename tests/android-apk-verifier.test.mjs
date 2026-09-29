import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const dir = mkdtempSync(join(tmpdir(), 'vex-apk-verify-'));
try {
  const apk = join(dir, 'fixture.apk');
  const aapt = join(dir, 'aapt');
  writeFileSync(aapt, '#!/bin/sh\nprintf "package: name=\'com.vexguard.app.dev\' versionCode=\'1\' versionName=\'1.dev\'\\n"\n');
  chmodSync(aapt, 0o755);
  const make = spawnSync('python3', ['-c', `
import zipfile,sys
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('assets/index.android.bundle', b'x' * 100001)
    for name in ('libwg-go.so', 'libwg.so', 'libwg-quick.so'):
        z.writestr('lib/arm64-v8a/' + name, b'ELF')
    for i in range(6000):
        z.writestr('assets/filler-%05d.dat' % i, b'')
`, apk], { encoding: 'utf8' });
  assert.equal(make.status, 0, make.stderr);

  const verified = spawnSync('bash', ['scripts/verify_android_apk.sh', apk, 'com.vexguard.app.dev', '1', '1.dev', 'arm64-v8a'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, AAPT_BIN: aapt },
    encoding: 'utf8',
  });
  assert.equal(verified.status, 0, verified.stderr);
  assert.match(verified.stdout, /Verified APK:/);
  console.log('ANDROID_APK_VERIFIER_LARGE_MANIFEST=PASS');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
