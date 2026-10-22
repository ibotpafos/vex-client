import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';

const root = fileURLToPath(new URL('../', import.meta.url));
// Allow the previous workflow to be exercised as a regression fixture.
const workflow = YAML.parse(fs.readFileSync(process.env.VEX_ANDROID_CANDIDATE_WORKFLOW_SOURCE
  || path.join(root, '.github/workflows/android-sign-candidate.yml'), 'utf8'));
const sourceStep = workflow.jobs.release.steps.find(step => step.id === 'source');
const sdkStep = workflow.jobs.release.steps.find(step => step.name === 'Install locked Android SDK');
const installer = fs.readFileSync(path.join(root, 'scripts/install_android_sdk_components.sh'));
const packages = fs.readFileSync(path.join(root, 'scripts/android_sdk_packages.txt'));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

for (const mode of ['current', 'qualified', 'native-routing']) {
  test(`Android SDK preparation preserves the ${mode} candidate source`, () => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'vex-candidate-sdk-history-'));
    try {
      const repo = path.join(temp, 'candidate source');
      const runner = path.join(temp, 'runner temp');
      const hooks = path.join(temp, 'empty hooks');
      const sdk = path.join(temp, 'SDK with spaces');
      for (const directory of [repo, runner, hooks]) fs.mkdirSync(directory);
      const env = { ...process.env };
      // Keep the miniature repository independent of the invoking Git worktree.
      for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
      Object.assign(env, {
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: os.devNull, GIT_TERMINAL_PROMPT: '0',
        GIT_AUTHOR_NAME: 'Candidate fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
        GIT_COMMITTER_NAME: 'Candidate fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
        RUNNER_TEMP: runner, GITHUB_OUTPUT: path.join(runner, 'outputs'),
        GITHUB_PATH: path.join(runner, 'path'), ANDROID_HOME: sdk, ANDROID_SDK_ROOT: '',
        VEX_TEST_SDK_EVENTS: path.join(runner, 'events'),
        VEX_TEST_SDK_MANIFEST: path.join(runner, 'requested-packages'),
        QUALIFIED_SOURCE_REQUESTED: String(mode === 'qualified'),
        NATIVE_ROUTING_SOURCE_REQUESTED: String(mode === 'native-routing'),
        PYTHONDONTWRITEBYTECODE: '1',
      });
      delete env.VEX_ANDROID_SDK_ORCHESTRATION;
      const run = (command, args) => execFileSync(command, args, {
        cwd: repo, env, encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe'],
      }).trim();
      const git = (...args) => run('git', ['-c', `core.hooksPath=${hooks}`, '-c', 'commit.gpgSign=false', ...args]);
      git('-c', 'init.defaultBranch=fixture', 'init');
      const commit = marker => {
        fs.writeFileSync(path.join(repo, 'source-marker'), marker);
        git('add', '.');
        git('commit', '-m', marker);
        return { commit: git('rev-parse', 'HEAD'), tree: git('rev-parse', 'HEAD^{tree}') };
      };
      // Both historical trees deliberately predate the shared SDK scripts.
      const qualified = commit('qualified');
      const routing = commit('native-routing');
      fs.mkdirSync(path.join(repo, 'scripts'));
      fs.writeFileSync(path.join(repo, 'scripts/install_android_sdk_components.sh'), installer);
      fs.writeFileSync(path.join(repo, 'scripts/android_sdk_packages.txt'), packages);
      const orchestration = commit('orchestration');
      Object.assign(env, {
        GITHUB_SHA: orchestration.commit,
        QUALIFIED_SOURCE_COMMIT: qualified.commit, QUALIFIED_SOURCE_TREE: qualified.tree,
        NATIVE_ROUTING_SOURCE_COMMIT: routing.commit, NATIVE_ROUTING_SOURCE_TREE: routing.tree,
      });
      const selected = mode === 'qualified' ? qualified : mode === 'native-routing' ? routing : orchestration;

      // Only inert local SDK executables run: no downloads, Gradle or signing.
      const executable = (relative, source) => {
        const target = path.join(sdk, relative);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, `#!/bin/sh\nset -eu\n${source}`, { mode: 0o755 });
      };
      executable('cmdline-tools/latest/bin/sdkmanager', `
printf 'sdkmanager\\n' >> "$VEX_TEST_SDK_EVENTS"
[ "$#" -eq 1 ]
case "$1" in --package_file=*) cat "${'${1#--package_file=}'}" > "$VEX_TEST_SDK_MANIFEST" ;; *) exit 9 ;; esac
`);
      executable('cmake/3.22.1/bin/cmake', `
printf 'cmake\\n' >> "$VEX_TEST_SDK_EVENTS"
[ "$1" = '--version' ]
printf 'cmake version 3.22.1\\n'
`);

      run('bash', ['-c', sourceStep.run]);
      assert.equal(git('rev-parse', 'HEAD'), selected.commit);
      assert.equal(git('rev-parse', 'HEAD^{tree}'), selected.tree);
      const output = Object.fromEntries(fs.readFileSync(env.GITHUB_OUTPUT, 'utf8').trim().split('\n')
        .map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
      assert.equal(output.commit, selected.commit);
      if (sdkStep.env?.VEX_ANDROID_SDK_ORCHESTRATION) {
        assert.ok(output.sdk_directory.startsWith(`${runner}${path.sep}`));
        env.VEX_ANDROID_SDK_ORCHESTRATION = output.sdk_directory;
      }
      run('bash', ['-c', sdkStep.run]);
      assert.equal(fs.readFileSync(env.VEX_TEST_SDK_MANIFEST, 'utf8'), packages.toString());
      assert.deepEqual(fs.readFileSync(env.VEX_TEST_SDK_EVENTS, 'utf8').trim().split('\n'), ['sdkmanager', 'cmake']);
      assert.equal(git('rev-parse', 'HEAD'), selected.commit);
      assert.equal(git('status', '--porcelain'), '');
      const binding = JSON.parse(fs.readFileSync(path.join(runner, 'android-source-binding.json'), 'utf8'));
      assert.equal(binding.source_commit, selected.commit);
      assert.equal(binding.source_tree, selected.tree);
      assert.equal(binding.orchestration_workflow_commit, orchestration.commit);
      if (sdkStep.env?.VEX_ANDROID_SDK_ORCHESTRATION) {
        assert.equal(binding.sdk_installer_sha256, sha256(installer));
        assert.equal(binding.sdk_packages_sha256, sha256(packages));
        // Exercise only receipt construction with inert APK/mapping bytes.
        // Never execute the privileged build/signing commands around it.
        const build = workflow.jobs.release.steps.find(step => step.env?.ANDROID_RELEASE_KEYSTORE_BASE64);
        const receiptPython = build.run.match(/python3 - <<'PY_SIGNED_RECEIPT'\n([\s\S]*?)\nPY_SIGNED_RECEIPT/);
        assert.ok(receiptPython, 'Retained candidate receipt construction exists');
        fs.mkdirSync(path.join(repo, 'dist/android'), { recursive: true });
        fs.mkdirSync(path.join(repo, 'android/app/build/outputs/mapping/release'), { recursive: true });
        fs.writeFileSync(path.join(repo, 'dist/android/fixture.apk'), 'inert fixture bytes');
        fs.writeFileSync(path.join(repo, 'dist/android/release-manifest.json'), JSON.stringify({ version: '0.0.0' }));
        fs.writeFileSync(path.join(repo, 'app.json'), JSON.stringify({ expo: { android: { package: 'fixture.invalid', versionCode: 1 } } }));
        fs.writeFileSync(path.join(repo, 'android/app/build/outputs/mapping/release/mapping.txt'), 'inert fixture mapping');
        Object.assign(env, { SIGNED_APK_PATH: 'dist/android/fixture.apk', GITHUB_RUN_ID: '1', GITHUB_RUN_ATTEMPT: '1' });
        run('python3', ['-c', receiptPython[1]]);
        for (const outputPath of ['dist/android/signed-candidate-receipt.json', 'android-r8-provenance/provenance.json']) {
          const receipt = JSON.parse(fs.readFileSync(path.join(repo, outputPath), 'utf8'));
          assert.equal(receipt.sdk_installer_sha256, sha256(installer));
          assert.equal(receipt.sdk_packages_sha256, sha256(packages));
          assert.equal(receipt.source_commit, selected.commit);
          assert.equal(receipt.source_tree, selected.tree);
        }
      }
    } finally {
      fs.rmSync(temp, { recursive: true, force: true });
    }
  });
}
