import assert from 'node:assert/strict';
import fs from 'node:fs';
import YAML from 'yaml';

export function check(workflow) {
  assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.equal(workflow.concurrency['cancel-in-progress'], false);
  assert.deepEqual(Object.keys(workflow.jobs), ['release']);
  const job = workflow.jobs.release;
  assert.equal(job.if, "github.event_name == 'workflow_dispatch' && github.repository == 'ibotpafos/vex-client' && (github.ref == 'refs/heads/main' || (github.ref == 'refs/heads/codex/ru-direct-native-20261013' && github.actor == 'ibotpafos' && inputs.native_routing_source && !inputs.qualified_source && !inputs.dns_reliability_source) || (github.ref == 'refs/heads/codex/dns-stream-recovery-20261024' && github.actor == 'ibotpafos' && inputs.dns_reliability_source && !inputs.qualified_source && !inputs.native_routing_source))");
  assert.equal(job.environment, 'android-candidate-signing');
  assert.equal(job['runs-on'], 'ubuntu-24.04');
  assert.equal(job.env.ANDROID_RELEASE_ABIS, 'arm64-v8a,armeabi-v7a');
  assert.equal(job.permissions, undefined);
  assert.equal(job.env.ANDROID_RELEASE_KEYSTORE_BASE64, undefined);
  assert.equal(job.env.NATIVE_ROUTING_SOURCE_COMMIT, '07058bc912a2c523d79908548047496c723821cd');
  assert.equal(job.env.NATIVE_ROUTING_SOURCE_TREE, '1799b429665619ad18d1b6868b49b346741041cf');
  assert.equal(job.env.DNS_RELIABILITY_SOURCE_COMMIT, 'cc63b55058912eccabc28ff395e105927df11f5b');
  assert.equal(job.env.DNS_RELIABILITY_SOURCE_TREE, '628c7b63b703e11ecf0cd8161d3aa87b120bb42a');
  assert.deepEqual(workflow.on.workflow_dispatch.inputs.dns_reliability_source, {
    description: 'Sign the fixed reviewed cc63b55 Android DNS capacity/recovery 1.0.81 candidate without publication',
    type: 'boolean', required: false, default: false,
  });
  assert.equal(job.env.DNS_RELIABILITY_SOURCE_REQUESTED, "${{ inputs.dns_reliability_source && 'true' || 'false' }}");
  const sourceBinding = job.steps.find(step => step.id === 'source').run;
  assert.ok(sourceBinding.includes('for requested in "$QUALIFIED_SOURCE_REQUESTED" "$NATIVE_ROUTING_SOURCE_REQUESTED" "$DNS_RELIABILITY_SOURCE_REQUESTED"; do'));
  assert.ok(sourceBinding.includes('requested_sources=$((requested_sources + 1))'));
  assert.ok(sourceBinding.includes('if (( requested_sources > 1 )); then'));
  assert.ok(sourceBinding.includes('git checkout --detach "$DNS_RELIABILITY_SOURCE_COMMIT"'));
  assert.ok(sourceBinding.includes('test "$(git rev-parse HEAD^{tree})" = "$DNS_RELIABILITY_SOURCE_TREE"'));
  assert.ok(sourceBinding.includes('"dns_reliability_source_requested": os.environ["DNS_RELIABILITY_SOURCE_REQUESTED"] == "true"'));
  assert.ok(sourceBinding.includes('git checkout --detach "$NATIVE_ROUTING_SOURCE_COMMIT"'));
  assert.ok(sourceBinding.includes('test "$(git rev-parse HEAD^{tree})" = "$NATIVE_ROUTING_SOURCE_TREE"'));
  const quality = job.steps.findIndex(step => step.run === 'npm run check');
  const signing = job.steps.findIndex(step => step.env?.ANDROID_RELEASE_KEYSTORE_BASE64);
  assert.ok(quality >= 0 && signing > quality);
  assert.ok(job.steps.findIndex(step => step.id === 'source') < job.steps.findIndex(step => step.env?.KEYSTORE_PRESENT));
  assert.equal(job.steps.filter(step => step.env?.ANDROID_RELEASE_KEYSTORE_BASE64).length, 1);
  for (const step of job.steps) {
    if (step.uses) assert.match(step.uses, /^actions\/[a-z-]+@[0-9a-f]{40}$/);
    if (step.uses?.startsWith('actions/checkout@')) {
      assert.equal(step.with['persist-credentials'], false);
      assert.equal(step.with.ref, undefined);
    }
  }
  assert.equal(job.steps.find(step => step.uses?.startsWith('actions/setup-go@')).with['go-version'], '1.26.9');
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
  w => w.jobs.release.if = w.jobs.release.if.replace("github.actor == 'ibotpafos'", 'true'),
  w => w.jobs.release.env.NATIVE_ROUTING_SOURCE_COMMIT = '${{ inputs.ref }}',
  w => w.jobs.release.env.NATIVE_ROUTING_SOURCE_TREE = '0'.repeat(40),
  w => w.jobs.release.env.DNS_RELIABILITY_SOURCE_COMMIT = '${{ inputs.ref }}',
  w => w.jobs.release.env.DNS_RELIABILITY_SOURCE_TREE = '0'.repeat(40),
  w => w.jobs.release.steps.find(step => step.id === 'source').run = w.jobs.release.steps.find(step => step.id === 'source').run.replace('requested_sources > 1', 'requested_sources > 2'),
  w => w.jobs.release.if = w.jobs.release.if.replace('!inputs.dns_reliability_source', 'true'),
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
console.log(JSON.stringify({ status: 'pass', signedCandidateOnly: true, fixedNativeSource: true, negativeFixtures }));
