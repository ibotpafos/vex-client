import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / "run_test_with_failure_summary.py"


class FailureSummaryTests(unittest.TestCase):
    def run_fixture(self, source):
        return subprocess.run([sys.executable, str(WRAPPER), sys.executable, "-c", source],
                              capture_output=True, timeout=10)

    def test_success_preserves_output_without_failure_summary(self):
        result = self.run_fixture("import sys; print('out'); print('err',file=sys.stderr)")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"out\n", result.stdout)
        self.assertIn(b"err\n", result.stdout)
        self.assertNotIn(b"Test failure summary", result.stdout)

    def test_failure_at_start_survives_a_large_tail_without_changing_exit(self):
        result = self.run_fixture("import sys; print('Fixture.swift:17: error: -[Suite testCase] : XCTAssertEqual failed'); print('later pass\\n'*30000); sys.exit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertGreater(len(result.stdout), 120000)
        tail = result.stdout.rsplit(b"Test failure summary", 1)[1]
        self.assertIn(b"Fixture.swift:17", tail)
        self.assertIn(b"XCTAssertEqual failed", tail)

    def test_compiler_failure_is_retained(self):
        result = self.run_fixture("import sys; print('Fixture.swift:7:9: error: missing symbol'); sys.exit(1)")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"missing symbol", result.stdout.rsplit(b"Test failure summary", 1)[1])

    def test_unknown_failure_never_becomes_success(self):
        result = self.run_fixture("import sys; print('unknown fixture failure'); sys.exit(3)")
        self.assertEqual(result.returncode, 3)
        self.assertIn(b"No XCTest/compiler diagnostic line captured", result.stdout)

    def test_retained_diagnostics_and_lines_are_bounded(self):
        result = self.run_fixture("import sys; print('XCTAssertEqual '+('x'*1000000)); print('error: many\\n'*100); sys.exit(1)")
        self.assertEqual(result.returncode, 1)
        tail = result.stdout.rsplit(b"Test failure summary", 1)[1]
        self.assertLess(len(tail), 20 * 8193 + 200)
        self.assertEqual(tail.count(b"error: many"), 19)

    def test_missing_executable_preserves_failure(self):
        result = subprocess.run([sys.executable, str(WRAPPER), "/nonexistent/isolated-fixture"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 127)

    def test_wrapper_termination_reaps_its_owned_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            source = "import os,pathlib,time; pathlib.Path(os.environ['SUMMARY_CHILD_PID']).write_text(str(os.getpid())); time.sleep(2)"
            env = {**os.environ, "SUMMARY_CHILD_PID": str(pid_file)}
            wrapper = subprocess.Popen([sys.executable, str(WRAPPER), sys.executable, "-c", source],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists())
                child_pid = int(pid_file.read_text())
                wrapper.terminate()
                wrapper.communicate(timeout=8)
                self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if wrapper.poll() is None:
                    try:
                        wrapper.terminate()
                        wrapper.communicate(timeout=8)
                    except subprocess.TimeoutExpired:
                        wrapper.kill()
                wrapper.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
