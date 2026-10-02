import importlib.util
import json
import tempfile
import subprocess
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
    def publish_protocol_fixture(self, root, draft_changes=None, remote_changes=None,
                                 probe_code=1, probe_stderr=b"release not found", ref_sha=None):
        expected, _ = self.android_builder_fixture(root)
        expected["dry_run"] = False
        release.bundle(root, expected)
        api = f"https://api.github.com/repos/{release.REPO}/releases/123"
        draft = {"apiUrl": api, "tagName": expected["tag"], "isDraft": True,
                 "targetCommitish": expected["source_commit"], **(draft_changes or {})}
        remote = {"id": 123, "draft": True, "tag_name": expected["tag"],
                  "target_commitish": expected["source_commit"],
                  "assets": [{"name": p.name, "digest": "sha256:" + release.sha(p)} for p in root.iterdir()],
                  **(remote_changes or {})}
        calls = []
        self.publish_calls = calls

        def fake_command(*args):
            calls.append(args)
            if args[:2] == ("gh", "api"):
                if args[2] == f"repos/{release.REPO}/git/ref/tags/{expected['tag']}":
                    return json.dumps({"object": {"type": "commit", "sha": ref_sha or expected["source_commit"]}})
                if args[2] == api:
                    return json.dumps(remote)
                if "/releases/tags/" in args[2]:
                    # Native GitHub behavior observed for an unpublished draft.
                    raise subprocess.CalledProcessError(1, args, stderr="Not Found (HTTP 404)")
            if args[:3] == ("gh", "release", "view") and "--json" in args:
                return json.dumps(draft)
            if args[:3] in (("gh", "release", "create"), ("gh", "release", "upload")):
                return ""
            if args[:3] == ("gh", "release", "edit"):
                self.assertIn("--draft=false", args)
                self.assertIn("--latest=false", args)
                return ""
            raise AssertionError(f"Unexpected mocked publish command: {args}")

        probe = subprocess.CompletedProcess(["gh", "release", "view"], probe_code, b"", probe_stderr)
        with patch.dict("os.environ", {"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": expected["tag"]}), \
                patch.object(release, "command", fake_command), patch.object(release.subprocess, "run", return_value=probe):
            result = release.publish(root, expected)
        return result, calls

    def test_publish_draft_via_numeric_id_only_after_digest_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, calls = self.publish_protocol_fixture(Path(tmp))
            self.assertEqual(result["status"], "published")
            actions = [c[2] for c in calls if c[:2] == ("gh", "release")]
            self.assertEqual(actions, ["create", "upload", "view", "edit"])
            self.assertTrue(any(c[:3] == ("gh", "api", f"https://api.github.com/repos/{release.REPO}/releases/123") for c in calls))
            self.assertFalse(any("/releases/tags/" in c[2] for c in calls if c[:2] == ("gh", "api")))

    def test_publish_rejects_foreign_or_changed_draft_identity(self):
        fixtures = [("apiUrl", "https://evil.invalid/releases/123"),
                    ("apiUrl", "https://api.github.com/repos/other/repo/releases/123"),
                    ("apiUrl", f"https://api.github.com/repos/{release.REPO}/releases/123?redirect=1"),
                    ("apiUrl", f"https://api.github.com/repos/{release.REPO}/releases/not-numeric"),
                    ("tagName", "android-v0.0.0"), ("isDraft", False), ("targetCommitish", "b" * 40)]
        for key, value in fixtures:
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    self.publish_protocol_fixture(Path(tmp), draft_changes={key: value})
                self.assertFalse(any(c[:3] == ("gh", "release", "edit") for c in self.publish_calls))

    def test_publish_rejects_remote_draft_identity_or_asset_mismatch(self):
        fixtures = [("id", 124), ("id", True), ("draft", False), ("tag_name", "android-v0.0.0"),
                    ("target_commitish", "b" * 40), ("assets", []),
                    ("assets", [{"name": "fixture.apk", "digest": "sha256:" + "b" * 64}])]
        for key, value in fixtures:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    self.publish_protocol_fixture(Path(tmp), remote_changes={key: value})
                self.assertFalse(any(c[:3] == ("gh", "release", "edit") for c in self.publish_calls))

    def test_publish_preserves_existing_release_and_fails_closed_on_probe_error(self):
        for code, stderr in ((0, b""), (1, b"Forbidden (HTTP 403)"), (1, b"network timeout")):
            with self.subTest(code=code, stderr=stderr), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    self.publish_protocol_fixture(Path(tmp), probe_code=code, probe_stderr=stderr)
                self.assertFalse(any(c[:2] == ("gh", "release") for c in self.publish_calls))

    def test_publish_rejects_moved_tag_before_creating_draft(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                self.publish_protocol_fixture(Path(tmp), ref_sha="b" * 40)
            self.assertFalse(any(c[:2] == ("gh", "release") for c in self.publish_calls))

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
            native = {"version": expected["version"], "build": str(expected["build"]), "archive": "fixture.zip",
                      "updateSignatureScheme": "sparkle-ed25519", "sparklePublicEDKey": "fixture-public-key",
                      "selfSigned": True, "notarized": False, "appleDeveloperSigned": False, "gatekeeperReady": False}
            (root / "fixture.zip").write_bytes(b"contract-fixture-not-a-real-signed-archive")
            (root / "release-manifest.json").write_text(json.dumps(native))
            result = release.bundle(root, expected)
            self.assertEqual(result["build"], SOURCE["native_macos"]["build"])
            (root / "release-manifest.json").write_text(json.dumps({**native, "build": expected["build"]}))
            self.assertEqual(release.bundle(root, expected)["build"], expected["build"])
            for field, value in (("build", expected["build"] + 1), ("build", str(expected["build"] + 1)),
                                 ("build", "invalid"), ("build", True), ("build", float(expected["build"])),
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
