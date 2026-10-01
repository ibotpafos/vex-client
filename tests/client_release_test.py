import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "scripts/client_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

SOURCE = json.loads((release.ROOT / "versions.json").read_text())
ANDROID_TAG = "android-v" + SOURCE["android"]["version"]
MAC_TAG = "macos-v" + SOURCE["native_macos"]["version"]

class ReleaseContract(unittest.TestCase):
    def test_existing_android_dry_run(self):
        result = release.plan(ANDROID_TAG, True)
        self.assertEqual(result["build"], json.loads((release.ROOT / "app.json").read_text())["expo"]["android"]["versionCode"])
        self.assertTrue(result["dry_run"])

    def test_native_mac_version_source(self):
        result = release.plan(MAC_TAG, True)
        self.assertEqual(result["build"], SOURCE["native_macos"]["build"])

    def test_reject_inactive_platform_and_bad_tags(self):
        for tag in ("ios-v1.0.61", "windows-v1.0.61", "android-v999.0.0", "android-v01.0.61", "android-v1.0.61;echo unsafe", "v1.0.61"):
            with self.subTest(tag=tag), self.assertRaises((ValueError, KeyError)):
                release.plan(tag, False)

    def test_android_package_and_version_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            versions = json.loads((release.ROOT / "versions.json").read_text())
            versions["android"]["release_status"] = "candidate"
            (root / "versions.json").write_text(json.dumps(versions))
            app = json.loads((release.ROOT / "app.json").read_text())
            for key, value in (("package", "com.vexguard.app.debug"), ("versionCode", 1)):
                modified = json.loads(json.dumps(app))
                modified["expo"]["android"][key] = value
                (root / "app.json").write_text(json.dumps(modified))
                with self.assertRaises(ValueError):
                    release.plan(ANDROID_TAG, False, root)

    def test_bundle_tamper_path_and_origin(self):
        expected = {**release.plan(ANDROID_TAG, True), "source_commit": "a" * 40}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "fixture.apk").write_bytes(b"signed-fixture-not-a-real-apk")
            manifest = {**expected, "assets": [{"name": "fixture.apk", "size": (root / "fixture.apk").stat().st_size, "sha256": release.sha(root / "fixture.apk"), "url": f"https://github.com/{release.REPO}/releases/download/{expected['tag']}/fixture.apk"}]}
            (root / "vex-release.json").write_text(json.dumps(manifest))
            release.verify_bundle(root, expected)
            for field, value in (("sha256", "b" * 64), ("size", 0), ("url", "https://evil.invalid/fixture.apk"), ("name", "../fixture.apk")):
                modified = json.loads(json.dumps(manifest))
                modified["assets"][0][field] = value
                (root / "vex-release.json").write_text(json.dumps(modified))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    release.verify_bundle(root, expected)
