import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install_android_sdk_components.sh"


class AndroidSdkComponentsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vex-sdk-components-")
        self.addCleanup(self.temp.cleanup)
        self.case = Path(self.temp.name)
        self.sdk = self.case / "SDK with spaces"
        self.events = self.case / "events"
        self.manifest = self.case / "requested-packages"
        self.env = dict(os.environ, ANDROID_HOME=str(self.sdk), ANDROID_SDK_ROOT="",
                        VEX_TEST_SDK_EVENTS=str(self.events), VEX_TEST_SDK_MANIFEST=str(self.manifest))

    def executable(self, relative, source):
        target = self.sdk / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("#!/bin/sh\nset -eu\n" + source)
        target.chmod(0o755)

    def manager(self):
        self.executable("cmdline-tools/latest/bin/sdkmanager", """
printf 'sdkmanager\n' >> "$VEX_TEST_SDK_EVENTS"
[ "$#" -eq 1 ]
case "$1" in --package_file=*) cat "${1#--package_file=}" > "$VEX_TEST_SDK_MANIFEST" ;; *) exit 9 ;; esac
exit "${VEX_TEST_SDK_EXIT:-0}"
""")

    def cmake(self):
        self.executable("cmake/3.22.1/bin/cmake", """
printf 'cmake\n' >> "$VEX_TEST_SDK_EVENTS"
[ "$1" = '--version' ]
printf 'cmake version 3.22.1\n'
""")

    def run_installer(self):
        # The real wrapper calls only these inert files. No SDK/network/Gradle.
        return subprocess.run(["bash", str(INSTALLER)], cwd=self.case, env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_manifest_and_cmake_probe_use_the_configured_sdk_in_order(self):
        self.manager()
        self.cmake()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events.read_text().splitlines(), ["sdkmanager", "cmake"])
        self.assertEqual(self.manifest.read_text(), (ROOT / "scripts/android_sdk_packages.txt").read_text())
        self.assertIn("cmake;3.22.1", self.manifest.read_text().splitlines())

    def test_sdk_manager_failure_propagates_without_a_retry_or_compiler_probe(self):
        self.manager()
        self.cmake()
        self.env["VEX_TEST_SDK_EXIT"] = "7"
        self.assertEqual(self.run_installer().returncode, 7)
        self.assertEqual(self.events.read_text().splitlines(), ["sdkmanager"])

    def test_a_silent_missing_cmake_install_cannot_pass_preflight(self):
        self.manager()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Pinned CMake was not installed", result.stderr)
        self.assertEqual(self.events.read_text().splitlines(), ["sdkmanager"])

    def test_an_unconfigured_sdk_never_falls_back_to_a_path_shadow(self):
        trap = self.case / "bin"
        trap.mkdir()
        shadow = trap / "sdkmanager"
        shadow.write_text("#!/bin/sh\nprintf unexpected > \"$VEX_TEST_SDK_EVENTS\"\n")
        shadow.chmod(0o755)
        self.env["PATH"] = str(trap) + os.pathsep + self.env["PATH"]
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.events.exists())


if __name__ == "__main__":
    unittest.main()
