import assert from 'node:assert/strict';
import fs from 'node:fs';
import YAML from 'yaml';

const workflow = process.argv[2] ?? '.github/workflows/native-reliability-ci.yml';
const document = YAML.parseDocument(fs.readFileSync(workflow, 'utf8'));
assert.equal(document.errors.length, 0, 'Workflow must be valid YAML');
const config = document.toJS();
const lanes = { shared: 'ubuntu-24.04', android: 'ubuntu-24.04', macos: 'macos-26' };

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
    for (const step of (job.steps ?? []).filter(value => value.uses?.startsWith('actions/upload-artifact@'))) {
      // The only exception is short-lived, owned-PR transaction evidence. It
      // contains no compiled binaries and is never consumed by a release job.
      if (lane !== 'macos' || step.name !== 'Retain only helper transaction evidence'
        || step.uses !== 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
        || step.if !== "always() && steps.contract.outputs.ran == 'true'"
        || step.with?.name !== 'macos-contract-transaction'
        || step.with?.['retention-days'] !== 3
        || step.with?.path !== [
          '${{ runner.temp }}/macos-contract-transaction/MODIFIED_FILE.swift',
          '${{ runner.temp }}/macos-contract-transaction/DIFF_FILE.patch',
          '${{ runner.temp }}/macos-contract-transaction/VERIFICATION.txt',
          '${{ runner.temp }}/macos-contract-transaction/ROLLBACK.sh',
          '${{ runner.temp }}/macos-contract-transaction/RESULT.json',
          '${{ runner.temp }}/macos-contract-transaction/COMMAND_EVENTS.json',
        ].join('\n') + '\n') failures.push(`no routine artifact storage: ${lane}`);
    }
    const commands = (job.steps ?? []).map(step => step.run ?? '').join('\n');
    if (/npm run (?:ota:|.*:publish|.*:deploy-release)|package-native-windows\.ps1|publish-native-windows\.ps1|-allowProvisioningUpdates/.test(commands)) failures.push(`no signing/publication: ${lane}`);
    if (lane === 'android' && /(?:^|\n)\s*sdkmanager\s/.test(commands)) failures.push('explicit Android SDK tool path');
    if (lane === 'android' && !(job.steps ?? []).some(step => step.uses?.startsWith('actions/setup-go@') && step.with?.['go-version'] === '1.25.x')) failures.push('pinned upstream Go toolchain floor');
    if (lane === 'macos') {
      if (job.env?.DEVELOPER_DIR !== '/Applications/Xcode_26.6.app/Contents/Developer') failures.push('supported pinned Xcode toolchain');
      if (!(job.steps ?? []).some(step => step.run?.trim() === 'swift test --package-path macos-native')) failures.push('complete macOS suite');
      const transaction = (job.steps ?? []).find(step => step.id === 'contract');
      if (transaction?.if !== "github.event_name == 'pull_request'"
        || transaction?.env?.BASE_COMMIT !== '${{ github.event.pull_request.base.sha }}') failures.push('PR-only transaction baseline');
    }
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
    value => { value.jobs.macos['runs-on'] = 'macos-26-xlarge'; },
    value => { value.jobs.macos.env.DEVELOPER_DIR = '/Applications/Xcode_26.3.app/Contents/Developer'; },
    value => { value.jobs.android.steps.find(step => step.name === 'Install locked Android build components').run = 'sdkmanager \"platform-tools\"'; },
    value => { value.jobs.android.steps.find(step => step.uses?.startsWith('actions/setup-go@')).with['go-version'] = '1.24.x'; },
    value => { value.permissions.contents = 'write'; },
    value => { value.jobs.android.env = { SIGNING_KEY: '${{ secrets.PRODUCTION_KEY }}' }; },
    value => { value.jobs.shared.steps[0].with['persist-credentials'] = true; },
    value => { value.jobs.macos.steps.push({ uses: 'actions/upload-artifact@v4' }); },
    value => { value.jobs.macos.steps.find(step => step.name === 'Test all native macOS behavior').run += ' --filter SparkleUpdateTests'; },
    value => { value.jobs.macos.steps.find(step => step.id === 'contract').if = 'always()'; },
    value => { value.jobs.macos.steps.find(step => step.name === 'Retain only helper transaction evidence').with.path += 'dist/**'; },
  ];
  for (const mutate of mutations) {
    const candidate = structuredClone(config);
    mutate(candidate);
    assert.ok(violations(candidate).length > 0, 'Unsafe/incomplete CI fixture must be rejected');
  }
  console.log(JSON.stringify({ status: 'pass', lanes: Object.keys(lanes), negativeFixtures: mutations.length }));
}
