"""Inert hosted-runner cleanup admission tests: no sudo or file removals."""
import importlib.util
import os
from pathlib import Path
import types
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('android_runner', Path(__file__).resolve().parents[1] / 'scripts/prepare_android_release_runner.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class RunnerSpace(unittest.TestCase):
    def environment(self):
        return {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'Linux', 'GITHUB_REPOSITORY': 'ibotpafos/vex-client',
                'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_TYPE': 'tag',
                'GITHUB_REF': 'refs/tags/android-v1.0.86',
                'GITHUB_WORKSPACE': '/home/runner/work/vex-client/vex-client'}

    def test_local_self_hosted_fork_branch_and_foreign_workspace_refuse_before_sudo(self):
        for changed in ({'GITHUB_ACTIONS': ''}, {'RUNNER_ENVIRONMENT': 'self-hosted'},
                        {'RUNNER_OS': 'macOS'}, {'GITHUB_REPOSITORY': 'fork/vex-client'},
                        {'GITHUB_EVENT_NAME': 'pull_request'}, {'GITHUB_REF_TYPE': 'branch'},
                        {'GITHUB_REF': 'refs/tags/macos-v1'}, {'GITHUB_WORKSPACE': '/foreign'}):
            with self.subTest(changed=changed), patch.dict(os.environ, self.environment() | changed, clear=True), \
                    patch.object(m, 'ROOT', Path('/home/runner/work/vex-client/vex-client')), \
                    patch.object(m.subprocess, 'run') as run, self.assertRaises(ValueError):
                m.prepare(True)
            run.assert_not_called()

    def test_a_forged_hosted_environment_still_refuses_a_local_checkout(self):
        with patch.dict(os.environ, self.environment(), clear=True), \
                patch.object(m, 'ROOT', Path('/private/local-checkout')), \
                patch.object(m.subprocess, 'run') as run, self.assertRaises(ValueError):
            m.prepare(True)
        run.assert_not_called()

    def test_default_is_read_only_even_when_cleanup_targets_exist(self):
        with patch.object(m, 'removable', return_value=True), \
                patch.object(m.shutil, 'disk_usage', return_value=types.SimpleNamespace(free=m.MIN_FREE)), \
                patch.object(m.subprocess, 'run') as run:
            self.assertFalse(m.prepare()['executed'])
        run.assert_not_called()

    def test_symlinks_ancestor_symlinks_and_mounts_are_never_cleanup_targets(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            real = root / 'real'; real.mkdir()
            (real / 'nested').mkdir()
            link = root / 'link'; link.symlink_to(real, target_is_directory=True)
            self.assertTrue(m.removable(real))
            self.assertFalse(m.removable(link))
            self.assertFalse(m.removable(link / 'nested'))
            with patch.object(Path, 'is_mount', return_value=True):
                self.assertFalse(m.removable(real))

    def test_explicit_hosted_execution_uses_only_fixed_unused_tools_and_checks_space(self):
        with patch.dict(os.environ, self.environment(), clear=True), \
                patch.object(m, 'ROOT', Path('/home/runner/work/vex-client/vex-client')), \
                patch.object(m, 'removable', return_value=True), \
                patch.object(m.shutil, 'disk_usage', side_effect=[types.SimpleNamespace(free=1), types.SimpleNamespace(free=m.MIN_FREE)]), \
                patch.object(m.subprocess, 'run') as run:
            self.assertEqual(m.prepare(True)['free_after_bytes'], m.MIN_FREE)
        run.assert_called_once_with(['sudo', '-n', 'rm', '-rf', '--one-file-system', '--', *map(str, m.UNUSED)], check=True)

    def test_insufficient_space_fails_before_signing_can_begin(self):
        with patch.dict(os.environ, self.environment(), clear=True), \
                patch.object(m, 'ROOT', Path('/home/runner/work/vex-client/vex-client')), \
                patch.object(m, 'removable', return_value=False), \
                patch.object(m.shutil, 'disk_usage', return_value=types.SimpleNamespace(free=m.MIN_FREE - 1)), \
                patch.object(m.subprocess, 'run') as run, self.assertRaisesRegex(ValueError, '24 GiB'):
            m.prepare(True)
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
