import json
from pathlib import Path
import subprocess
import shlex
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'run_unit_groups.py'


class UnitGroupsTests(unittest.TestCase):
    def run_groups(self, commands, short_timeout=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'package.json').write_text(json.dumps({'scripts': {'test:unit': ' && '.join(commands)}}))
            command = [sys.executable, str(RUNNER)]
            if short_timeout:
                # Shorten only the first deadline; execute the real process lifecycle.
                bootstrap = '''import runpy, subprocess, sys
original = subprocess.Popen.communicate
shortened = False
def communicate(self, input=None, timeout=None):
    global shortened
    if timeout is not None and not shortened:
        timeout, shortened = 0.2, True
    return original(self, input=input, timeout=timeout)
subprocess.Popen.communicate = communicate
runpy.run_path(sys.argv[1], run_name='__main__')
'''
                command = [sys.executable, '-c', bootstrap, str(RUNNER)]
            result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=10)
            self.assertTrue((root / '.test-results/unit/results.json').exists(), result.stderr)
            rows = json.loads((root / '.test-results/unit/results.json').read_text())
            logs = [(root / '.test-results/unit' / row['stdout']).read_text() for row in rows]
            return result, rows, logs

    def test_failure_does_not_hide_later_groups_and_returns_failure(self):
        result, rows, logs = self.run_groups([
            'python3 -c "import sys; print(\'first\'); sys.exit(3)"',
            'python3 -c "print(\'second ran\')"',
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['exit'] for row in rows], [3, 0])
        self.assertEqual(logs, ['first\n', 'second ran\n'])

    def test_all_green_returns_success_and_keeps_arguments_quoted(self):
        result, rows, logs = self.run_groups(['python3 -c "print(\'two words\')"'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]['exit'], 0)
        self.assertEqual(logs, ['two words\n'])

    def test_missing_executable_is_recorded_and_later_group_still_runs(self):
        result, rows, logs = self.run_groups(['vex-fixture-missing-command', 'python3 -c "print(1)"'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['exit'] for row in rows], [127, 0])
        self.assertEqual(logs[1], '1\n')

    def test_timeout_kills_descendants_before_running_the_next_group(self):
        descendant = "import time; from pathlib import Path; time.sleep(0.8); Path('orphan-marker').touch()"
        first = shlex.join(['python3', '-c', f"import subprocess,time; subprocess.Popen(['python3','-c',{descendant!r}]); time.sleep(3)"])
        second = 'python3 -c "import time; from pathlib import Path; time.sleep(1); print(Path(\'orphan-marker\').exists())"'
        result, rows, logs = self.run_groups([first, second], short_timeout=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['exit'] for row in rows], [124, 0])
        self.assertEqual(logs[1], 'False\n', 'timed-out child leaked into the next group')


if __name__ == '__main__':
    unittest.main()
