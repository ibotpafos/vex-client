import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "scripts/client_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

SOURCE = json.loads((release.ROOT / "versions.json").read_text())
ANDROID_TAG = "android-v" + SOURCE["android"]["version"]
MAC_TAG = "macos-v" + SOURCE["native_macos"]["version"]

class ReleaseContract(unittest.TestCase):
    def android_builder_fixture(self, root):
        expected = {**release.plan(ANDROID_TAG, True), "source_commit": "a" * 40}
        name = f"Vex-Android-{expected['version']}-{SOURCE['android']['build']}.apk"
        # Producer-shaped contract fixture; real APK crypto is verified by the builder.
        (root / name).write_bytes(b"contract-fixture-not-a-real-signed-apk")
        (root / (name + ".sig")).write_text(f"Signer #1 certificate SHA-256 digest: {release.SIGNER}\n")
        native = {"version": expected["version"], "build": SOURCE["android"]["build"],
                  "variant": "release", "updater": name, "updaterSignature": name + ".sig",
                  "assets": [name, name + ".sig"]}
        (root / "release-manifest.json").write_text(json.dumps(native))
        return expected, native

    def test_android_builder_counter_becomes_encoded_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected, native = self.android_builder_fixture(root)
            result = release.bundle(root, expected)
            self.assertEqual(result["build"], expected["build"])
            self.assertEqual(native["build"], SOURCE["android"]["build"])
            self.assertEqual(result["download_asset"], native["updater"])
            self.assertEqual(result["signer_sha256"], release.SIGNER)
            self.assertEqual(release.verify_bundle(root, expected), result)

    def test_android_builder_rejects_wrong_counter_type_version_and_variant(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected, native = self.android_builder_fixture(root)
            for field, value in (("build", SOURCE["android"]["build"] + 1),
                                 ("build", expected["build"]), ("build", 0), ("build", 100),
                                 ("build", True), ("build", str(native["build"])),
                                 ("build", float(native["build"])), ("version", "9.9.9"),
                                 ("variant", "debug"), ("variant", "local")):
                modified = {**native, field: value}
                (root / "release-manifest.json").write_text(json.dumps(modified))
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    release.bundle(root, expected)

    def test_android_builder_rejects_wrong_signer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected, native = self.android_builder_fixture(root)
            (root / (native["updater"] + ".sig")).write_text("certificate SHA-256 digest: " + "b" * 64)
            with self.assertRaises(ValueError):
                release.bundle(root, expected)

    def test_android_counter_policy_boundaries(self):
        self.assertEqual(release.android_version_code("1.0.62", 70), 1006270)
        self.assertEqual(release.android_version_code("99.99.99", 99), 99999999)
        for version, counter in (("100.0.0", 1), ("1.100.0", 1), ("1.0.100", 1),
                                 ("01.0.62", 70), ("1.0.62-beta", 70), ("1.0.62", False)):
            with self.subTest(version=version, counter=counter), self.assertRaises(ValueError):
                release.android_version_code(version, counter)

    def test_macos_builder_keeps_unencoded_counter_and_distribution_policy(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"VEX_SELF_SIGNED_APP_CERT_SHA256": "c" * 64}):
            root = Path(tmp)
            expected = {**release.plan(MAC_TAG, True), "source_commit": "a" * 40}
            native = {"version": expected["version"], "build": expected["build"], "archive": "fixture.zip",
                      "updateSignatureScheme": "sparkle-ed25519", "sparklePublicEDKey": "fixture-public-key",
                      "selfSigned": True, "notarized": False, "appleDeveloperSigned": False, "gatekeeperReady": False}
            (root / "fixture.zip").write_bytes(b"contract-fixture-not-a-real-signed-archive")
            (root / "release-manifest.json").write_text(json.dumps(native))
            result = release.bundle(root, expected)
            self.assertEqual(result["build"], SOURCE["native_macos"]["build"])
            for field, value in (("build", expected["build"] + 1), ("build", str(expected["build"])),
                                 ("notarized", True), ("selfSigned", False), ("updateSignatureScheme", "none")):
                (root / "release-manifest.json").write_text(json.dumps({**native, field: value}))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    release.bundle(root, expected)

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
