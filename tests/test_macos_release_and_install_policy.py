import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MacOSReleaseAndInstallPolicyTest(unittest.TestCase):
    def read(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8")

    def test_installer_does_not_depend_on_lipo_inside_packagekit_sandbox(self) -> None:
        installer = self.read("macos-native/HelperResources/install-vex-vpn-helper.sh")
        preflight = self.read("scripts/native_macos_production_preflight.sh")

        self.assertNotIn('/usr/bin/lipo -archs "$src_dir/$required"', installer)
        self.assertIn('-verify_arch "${required_arch}"', preflight)

    def test_public_release_requires_distribution_signing_and_notarization(self) -> None:
        release = self.read("scripts/release_native_macos_autonomous.sh")

        self.assertIn("VEX_NATIVE_PRODUCTION=1", release)
        self.assertIn("VEX_NATIVE_REQUIRE_DEVELOPER_ID=1", release)
        self.assertIn("VEX_SPARKLE_REQUIRE_DEVELOPER_ID=1", release)
        self.assertIn("VEX_NOTARIZE=1", release)
        self.assertNotIn("build_native_macos_internal_release.sh", release)

    def test_public_deploy_bundle_contains_the_signed_installer(self) -> None:
        prepare = self.read("scripts/prepare_native_macos_deploy_bundle.sh")
        public_release = self.read("scripts/build_native_macos_public_release.sh")

        self.assertIn("package", prepare)
        self.assertIn("packageSHA256", prepare)
        self.assertIn("VEX_INSTALLER_SIGN_IDENTITY", public_release)
        self.assertIn("xcrun notarytool submit", public_release)
        self.assertIn('xcrun stapler staple "${pkg_path}"', public_release)
        self.assertNotIn("ZIP-only Sparkle distribution", prepare)

    def test_deploy_bundle_copies_versioned_archive_and_package(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archives = root / "archives"
            output = root / "deploy"
            archives.mkdir()
            files = {
                "VEXNativeMac-1.2.3-45.zip": b"archive",
                "VEXNativeMac-1.2.3-45.pkg": b"package",
                "appcast.xml": b"<rss/>",
            }
            for name, data in files.items():
                path = archives / name
                path.write_bytes(data)
                digest = hashlib.sha256(data).hexdigest()
                (archives / f"{name}.sha256").write_text(f"{digest}  {name}\n")
            manifest = {
                "archive": "VEXNativeMac-1.2.3-45.zip",
                "downloadURL": "https://vexguard.app/downloads/native-macos/VEXNativeMac-1.2.3-45.zip",
                "package": "VEXNativeMac-1.2.3-45.pkg",
                "packageDownloadURL": "https://vexguard.app/downloads/native-macos/VEXNativeMac-1.2.3-45.pkg",
                "packageSHA256": hashlib.sha256(files["VEXNativeMac-1.2.3-45.pkg"]).hexdigest(),
                "appleDeveloperSigned": True,
                "notarized": True,
                "gatekeeperReady": True,
            }
            (archives / "release-manifest.json").write_text(json.dumps(manifest))
            env = os.environ.copy()
            env.update({
                "VEX_SPARKLE_ARCHIVES_DIR": str(archives),
                "VEX_NATIVE_DEPLOY_BUNDLE_DIR": str(output),
            })
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "scripts/prepare_native_macos_deploy_bundle.sh")],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / manifest["archive"]).is_file())
            self.assertTrue((output / manifest["package"]).is_file())


if __name__ == "__main__":
    unittest.main()
