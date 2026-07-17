import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowPolicyTest(unittest.TestCase):
    def test_only_windows_and_linux_have_github_release_builds(self) -> None:
        self.assertTrue((WORKFLOWS / "windows-release.yml").exists())
        self.assertTrue((WORKFLOWS / "linux-release.yml").exists())
        self.assertFalse((WORKFLOWS / "android-release.yml").exists())
        self.assertFalse((WORKFLOWS / "macos-release.yml").exists())

    def test_github_release_builds_have_no_production_access(self) -> None:
        for name in ("windows-release.yml", "linux-release.yml"):
            workflow = (WORKFLOWS / name).read_text()
            self.assertNotIn("PRODUCTION_", workflow)
            self.assertNotIn("vexguard.app", workflow)
            self.assertNotIn("ssh-private-key", workflow)
            self.assertNotIn("production-deploy", workflow)
            self.assertIn("actions/upload-artifact@v4", workflow)
            self.assertIn("VEX_RUNTIME_VERSION", workflow)
            self.assertIn('require("./app.json").expo.version', workflow)

    def test_linux_appimagetool_status_does_not_pollute_resolved_path(self) -> None:
        script = (ROOT / "scripts" / "build_linux_release.sh").read_text()
        self.assertIn('echo "Downloading appimagetool for ${arch}" >&2', script)


if __name__ == "__main__":
    unittest.main()
