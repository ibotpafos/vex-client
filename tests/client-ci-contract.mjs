import assert from 'node:assert/strict';
import fs from 'node:fs';
import YAML from 'yaml';

const workflow = process.argv[2] ?? '.github/workflows/native-reliability-ci.yml';
const document = YAML.parseDocument(fs.readFileSync(workflow, 'utf8'));
assert.equal(document.errors.length, 0, 'Workflow must be valid YAML');
const config = document.toJS();
const lanes = { shared: 'ubuntu-24.04', android: 'ubuntu-24.04', macos: 'macos-15' };

function violations(value) {
  const failures = [];
  if (value.permissions?.contents !== 'read' || Object.values(value.permissions ?? {}).includes('write')) failures.push('read-only permissions');
  if (!value.on?.pull_request || !value.on?.push || !Object.hasOwn(value.on ?? {}, 'workflow_dispatch')) failures.push('PR/main/manual triggers');
  if (!value.concurrency?.group || value.concurrency?.['cancel-in-progress'] !== true) failures.push('bounded concurrency');
  const paths = value.on?.pull_request?.paths ?? [];
  for (const scope of ['src/**', 'app/**', 'assets/**', 'modules/**', 'scripts/**']) {
    if (!paths.includes(scope)) failures.push(`trigger coverage: ${scope}`);
  }
  for (const excluded of ['ios', 'windows']) {
    if (value.jobs?.[excluded]) failures.push(`paused/absent client lane: ${excluded}`);
  }
  for (const [lane, runner] of Object.entries(lanes)) {
    const job = value.jobs?.[lane];
    if (!job) { failures.push(`missing client lane: ${lane}`); continue; }
    if (job['runs-on'] !== runner) failures.push(`standard hosted runner: ${lane}`);
    if (!(job['timeout-minutes'] > 0 && job['timeout-minutes'] <= 60)) failures.push(`bounded timeout: ${lane}`);
    if (!job.if?.includes('github.event.pull_request.head.repo.full_name == github.repository')) failures.push(`fork guard: ${lane}`);
    if (Object.values(job.permissions ?? {}).includes('write')) failures.push(`job write permissions: ${lane}`);
    const checkouts = (job.steps ?? []).filter(step => step.uses?.startsWith('actions/checkout@'));
    if (checkouts.length !== 1 || checkouts[0].with?.['persist-credentials'] !== false) failures.push(`credential-free checkout: ${lane}`);
    if (JSON.stringify(job).includes('secrets.')) failures.push(`no production secrets: ${lane}`);
    if ((job.steps ?? []).some(step => step.uses?.startsWith('actions/upload-artifact@'))) failures.push(`no routine artifact storage: ${lane}`);
    const commands = (job.steps ?? []).map(step => step.run ?? '').join('\n');
    if (/npm run (?:ota:|.*:publish|.*:deploy-release)|package-native-windows\.ps1|publish-native-windows\.ps1|-allowProvisioningUpdates/.test(commands)) failures.push(`no signing/publication: ${lane}`);
    const required = {
      shared: ['npm run check', 'npm run build:web', 'actionlint'],
      android: ['sdkmanager', ':app:testDebugUnitTest', 'npm run android:build:debug:fast'],
      macos: ['swift build', '--target VEXNativeMac', 'swift test'],
    }[lane];
    for (const command of required) if (!commands.includes(command)) failures.push(`build/test command: ${lane}/${command}`);
  }
  return failures;
}

const failures = violations(config);
if (failures.length) {
  console.log(JSON.stringify({ status: 'fail', failures }));
  process.exitCode = 1;
} else {
  // Exercise actual negative configurations, not merely the happy path.
  const mutations = [
    value => { delete value.jobs.android; },
    value => { value.jobs.ios = structuredClone(value.jobs.macos); },
    value => { value.jobs.windows = structuredClone(value.jobs.macos); },
    value => { value.jobs.android['runs-on'] = 'ubuntu-latest-16-cores'; },
    value => { value.permissions.contents = 'write'; },
    value => { value.jobs.android.env = { SIGNING_KEY: '${{ secrets.PRODUCTION_KEY }}' }; },
    value => { value.jobs.shared.steps[0].with['persist-credentials'] = true; },
    value => { value.jobs.macos.steps.push({ uses: 'actions/upload-artifact@v4' }); },
  ];
  for (const mutate of mutations) {
    const candidate = structuredClone(config);
    mutate(candidate);
    assert.ok(violations(candidate).length > 0, 'Unsafe/incomplete CI fixture must be rejected');
  }
  console.log(JSON.stringify({ status: 'pass', lanes: Object.keys(lanes), negativeFixtures: mutations.length }));
}
