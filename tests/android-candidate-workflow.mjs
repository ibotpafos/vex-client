import assert from 'node:assert/strict';
import fs from 'node:fs';
import YAML from 'yaml';

export function check(workflow) {
  assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.equal(workflow.concurrency['cancel-in-progress'], false);
  assert.deepEqual(Object.keys(workflow.jobs), ['release']);
  const job = workflow.jobs.release;
  assert.equal(job.if, "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && github.repository == 'ibotpafos/vex-client'");
  assert.equal(job.environment, 'android-candidate-signing');
  assert.equal(job['runs-on'], 'ubuntu-24.04');
  assert.equal(job.env.ANDROID_RELEASE_ABIS, 'arm64-v8a,armeabi-v7a');
  assert.equal(job.permissions, undefined);
  assert.equal(job.env.ANDROID_RELEASE_KEYSTORE_BASE64, undefined);
  const quality = job.steps.findIndex(step => step.run === 'npm run check');
  const signing = job.steps.findIndex(step => step.env?.ANDROID_RELEASE_KEYSTORE_BASE64);
  assert.ok(quality >= 0 && signing > quality);
  assert.equal(job.steps.filter(step => step.env?.ANDROID_RELEASE_KEYSTORE_BASE64).length, 1);
  for (const step of job.steps) {
    if (step.uses) assert.match(step.uses, /^actions\/[a-z-]+@[0-9a-f]{40}$/);
    if (step.uses?.startsWith('actions/checkout@')) {
      assert.equal(step.with['persist-credentials'], false);
      assert.equal(step.with.ref, undefined);
    }
  }
  assert.equal(job.steps.find(step => step.uses?.startsWith('actions/setup-go@')).with['go-version'], '1.25.x');
  const build = job.steps[signing].run;
  assert.ok(build.includes('verify_android_signing_secret.sh cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470'));
  assert.ok(build.includes(':app:testDebugUnitTest'));
  assert.ok(build.includes('npm run android:release'));
  assert.ok(build.includes("trap 'rm -f \"$VEX_UPLOAD_STORE_FILE\"' EXIT"));
  assert.equal(job.steps.at(-1).if, 'always()');
  const source = JSON.stringify(workflow);
  for (const forbidden of ['VPN_ADMIN_TOKEN', 'VEX_RELEASE_REPOSITORY_TOKEN', 'gh release', 'client_release.py publish', 'verify_release_receipt.py']) {
    assert.ok(!source.includes(forbidden));
  }
}

const workflow = YAML.parse(fs.readFileSync(process.argv[2] || '.github/workflows/android-sign-candidate.yml', 'utf8'));
check(workflow);
let negativeFixtures = 0;
for (const mutate of [
  w => w.on.push = {},
  w => w.jobs.release.if = 'true',
  w => w.jobs.release.environment = undefined,
  w => w.permissions.contents = 'write',
  w => w.jobs.release.env.ANDROID_RELEASE_KEYSTORE_BASE64 = '${{ secrets.ANDROID_RELEASE_KEYSTORE_BASE64 }}',
  w => w.jobs.release.steps.find(step => step.run === 'npm run check').run = 'true',
  w => w.jobs.release.env.ANDROID_RELEASE_ABIS = 'arm64-v8a',
  w => w.jobs.release.steps[0].with.ref = '${{ inputs.ref }}',
]) {
  const invalid = structuredClone(workflow);
  mutate(invalid);
  assert.throws(() => check(invalid));
  negativeFixtures++;
}
console.log(JSON.stringify({ status: 'pass', signedCandidateOnly: true, mainOnly: true, negativeFixtures }));
