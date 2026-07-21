import os
import shutil
import subprocess
import tempfile
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
        self.assertIn('"${tool}" --comp zstd --no-appstream', script)
        self.assertNotIn('"${tool}" --comp xz --no-appstream', script)

    def test_local_release_cache_creates_missing_source_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            checkout = Path(temp_dir) / "checkout"
            scripts = checkout / "scripts"
            scripts.mkdir(parents=True)
            for name in ("local_release_env.sh", "setup_local_release_cache.sh"):
                shutil.copy2(ROOT / "scripts" / name, scripts / name)

            cache_root = Path(temp_dir) / "cache"
            env = os.environ.copy()
            env["VEX_LOCAL_RELEASE_CACHE_ROOT"] = str(cache_root)
            subprocess.run(
                ["bash", str(scripts / "setup_local_release_cache.sh")],
                check=True,
                cwd=checkout,
                env=env,
                capture_output=True,
                text=True,
            )

            external_amnezia = checkout / "external" / "amnezia"
            self.assertTrue(external_amnezia.is_symlink())
            self.assertEqual(external_amnezia.resolve(), (cache_root / "external-amnezia").resolve())


if __name__ == "__main__":
    unittest.main()
