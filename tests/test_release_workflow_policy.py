import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowPolicyTest(unittest.TestCase):
    def test_legacy_desktop_release_workflows_are_removed(self) -> None:
        self.assertFalse((WORKFLOWS / "windows-release.yml").exists())
        self.assertFalse((WORKFLOWS / "linux-release.yml").exists())

    def test_native_release_entrypoints_are_present(self) -> None:
        package = (ROOT / "package.json").read_text()
        self.assertIn('"native:macos:release"', package)
        self.assertIn('"native:windows:package"', package)
        self.assertNotIn('"' + 'ta' + 'uri:cli"', package)
        self.assertNotIn('"linux:release"', package)
        self.assertNotIn('"windows:release"', package)

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
