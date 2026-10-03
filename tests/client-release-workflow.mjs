import assert from 'node:assert/strict';
import fs from 'node:fs';
import YAML from 'yaml';
const path = process.argv[2] || '.github/workflows/client-release.yml';
function check(workflow) {
  assert.deepEqual(workflow.on.push.tags, ['android-v*', 'macos-v*']);
  assert.equal(workflow.on.push.branches, undefined);
  assert.equal(workflow.on.pull_request, undefined);
  assert.equal(workflow.on.pull_request_target, undefined);
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.equal(workflow.concurrency['cancel-in-progress'], false);
  assert.deepEqual(Object.keys(workflow.jobs).sort(), ['android', 'macos', 'prepare', 'publish', 'quality']);
  for (const [name, job] of Object.entries(workflow.jobs)) {
    for (const step of job.steps) {
      if (step.uses) assert.match(step.uses, /^actions\/[a-z-]+@[0-9a-f]{40}$/);
      if (step.uses?.startsWith('actions/checkout@')) assert.equal(step.with['persist-credentials'], false);
    }
    if (name === 'android' || name === 'macos') {
      assert.equal(job.environment, 'client-release-signing');
      assert.ok(job.if.includes("github.ref_type == 'tag'"));
      assert.ok(job.if.includes("dry_run == 'false'"));
      assert.ok(job.needs.includes('quality'));
    }
  }
  assert.ok(workflow.jobs.prepare.steps.some(s => s.run?.includes('"$AUTOPUBLISH_ENABLED" != true')));
  assert.equal(workflow.jobs.publish.environment, 'client-release-publish');
  assert.equal(workflow.jobs.publish.permissions.contents, 'write');
  assert.ok(workflow.jobs.publish.steps.some(s => s.uses?.startsWith('actions/attest-build-provenance@')));
  assert.ok(workflow.jobs.publish.steps.some(s => s.run?.includes('verify_release_receipt.py')));
  const r8 = workflow.jobs.android.steps.find(s => s.name === 'Bind separately retained R8 mapping to the signed APK');
  assert.ok(r8);
  assert.ok(r8.run.includes("node -e 'process.stdout.write(require(\"./dist/android/release-manifest.json\").updater)'"));
  assert.ok(r8.run.includes('android-r8-provenance/provenance.json'));
  assert.ok(r8.run.includes('dist/android/android-r8-provenance.json'));
  assert.ok(r8.run.includes('client_release.py bundle --directory dist/android'));
  const mappingArtifact = workflow.jobs.android.steps.find(s => s.with?.name === 'android-r8-mapping-${{ github.sha }}');
  assert.equal(mappingArtifact.with.path, 'android-r8-provenance/*');
  assert.ok(!JSON.stringify(workflow).includes('VPN_ADMIN_TOKEN'));
  assert.ok(!JSON.stringify(workflow).includes('VEX_RELEASE_REPOSITORY_TOKEN'));
}
const workflow = YAML.parse(fs.readFileSync(path, 'utf8'));
check(workflow);
let negatives = 0;
for (const mutate of [w => w.on.push.branches = ['main'], w => w.on.pull_request_target = {}, w => w.permissions.contents = 'write', w => w.jobs.android.environment = undefined, w => w.jobs.android.if = 'true', w => w.jobs.publish.environment = undefined, w => w.concurrency['cancel-in-progress'] = true, w => w.jobs.macos.steps[0].with['persist-credentials'] = true]) {
  const invalid = structuredClone(workflow); mutate(invalid); assert.throws(() => check(invalid)); negatives++;
}
console.log(JSON.stringify({ status: 'pass', releasePlatforms: ['android','macos'], negativeFixtures: negatives, signedTagsOnly: true }));
