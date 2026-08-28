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

    def test_self_signed_helper_install_pins_certificate_without_quarantine_bypass(self) -> None:
        package = self.read("scripts/build_native_macos_pkg.sh")
        installer = self.read("macos-native/HelperResources/install-vex-vpn-helper.sh")
        authenticator = self.read("macos-native/Sources/VEXHelperCore/PeerAuthenticator.swift")

        self.assertIn("VEX_EXPECTED_CERT_SHA256", package)
        self.assertIn("VEX_EXPECTED_CERT_SHA256", installer)
        self.assertIn("expectedCertificateSHA256", authenticator)
        self.assertNotIn("xattr -dr com.apple.quarantine", installer)

    def test_public_release_requires_distribution_signing_and_notarization(self) -> None:
        release = self.read("scripts/release_native_macos_autonomous.sh")

        self.assertIn("VEX_NATIVE_PRODUCTION=1", release)
        self.assertIn("VEX_NATIVE_REQUIRE_DEVELOPER_ID=1", release)
        self.assertIn("VEX_SPARKLE_REQUIRE_DEVELOPER_ID=1", release)
        self.assertIn("VEX_NOTARIZE=1", release)
        self.assertNotIn("build_native_macos_internal_release.sh", release)

    def test_self_signed_release_is_separate_and_explicitly_not_gatekeeper_ready(self) -> None:
        release = self.read("scripts/build_native_macos_self_signed_release.sh")

        self.assertIn('"channel": "self-signed"', release)
        self.assertIn('"selfSigned": True', release)
        self.assertIn('"notarized": False', release)
        self.assertIn('"gatekeeperReady": False', release)
        self.assertIn('"requiresManualApproval": True', release)
        self.assertIn('"packageSigned": False', release)
        self.assertIn('"packageTrust": "unsigned-manual-approval"', release)
        self.assertIn("unset VEX_INSTALLER_SIGN_IDENTITY", release)
        self.assertIn("VEXSelfSigned.entitlements", release)
        self.assertIn("generate_appcast", release)
        self.assertIn("sign_update", release)
        self.assertIn("--verify", release)
        self.assertIn("VEX_SPARKLE_PRIVATE_ED_KEY_FILE", release)
        self.assertNotIn('"installerSigningCertificateSHA256"', release)
        self.assertNotIn("notarytool submit", release)

    def test_self_signed_app_keeps_sparkle_with_narrow_runtime_exception(self) -> None:
        builder = self.read("scripts/build_native_macos_app.sh")
        preflight = self.read("scripts/native_macos_production_preflight.sh")
        entitlements = self.read("macos-native/VEXSelfSigned.entitlements")

        self.assertIn('VEX_CODESIGN_ENTITLEMENTS', builder)
        self.assertIn('--options runtime', builder)
        self.assertIn('automatic update checks enabled', preflight)
        self.assertIn('automatic update installation enabled', preflight)
        self.assertIn('Sparkle public key does not match', preflight)
        self.assertIn('com.apple.security.cs.disable-library-validation', entitlements)

    def test_self_signed_identity_setup_persists_sparkle_update_key(self) -> None:
        identity_script = self.read("scripts/create_native_macos_self_signed_identities.sh")

        self.assertIn("generate_keys", identity_script)
        self.assertIn("vex-vpn-self-signed", identity_script)
        self.assertIn("VEX_SPARKLE_PUBLIC_ED_KEY", identity_script)
        self.assertIn("VEX_SPARKLE_PRIVATE_ED_KEY_FILE", identity_script)
        self.assertNotIn("VEX_SELF_SIGNED_INSTALLER_CERT_PATH", identity_script)
        self.assertNotIn("VEX_INSTALLER_SIGN_IDENTITY", identity_script)

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

    def test_deploy_bundle_accepts_pinned_self_signed_channel(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archives = root / "archives"
            output = root / "deploy"
            archives.mkdir()
            files = {
                "VEXNativeMac-1.2.3-45-self-signed.zip": b"archive",
                "VEXNativeMac-1.2.3-45-self-signed.pkg": b"package",
                "appcast.xml": b"<rss/>",
            }
            for name, data in files.items():
                path = archives / name
                path.write_bytes(data)
                digest = hashlib.sha256(data).hexdigest()
                (archives / f"{name}.sha256").write_text(f"{digest}  {name}\n")
            manifest = {
                "channel": "self-signed",
                "distributionMode": "self-signed-manual-approval",
                "archive": "VEXNativeMac-1.2.3-45-self-signed.zip",
                "downloadURL": "https://vexguard.app/downloads/native-macos/VEXNativeMac-1.2.3-45-self-signed.zip",
                "package": "VEXNativeMac-1.2.3-45-self-signed.pkg",
                "packageDownloadURL": "https://vexguard.app/downloads/native-macos/VEXNativeMac-1.2.3-45-self-signed.pkg",
                "packageSHA256": hashlib.sha256(files["VEXNativeMac-1.2.3-45-self-signed.pkg"]).hexdigest(),
                "selfSigned": True,
                "signatureVerified": True,
                "packageSigned": False,
                "packageTrust": "unsigned-manual-approval",
                "automaticUpdates": True,
                "libraryValidationDisabled": True,
                "feedURL": "https://vexguard.app/downloads/native-macos/appcast.xml",
                "appcast": "appcast.xml",
                "appcastSHA256": "c" * 64,
                "sparklePublicEDKey": "d" * 44,
                "updateSignatureScheme": "sparkle-ed25519",
                "requiresManualApproval": True,
                "securityProtectionsDisabled": False,
                "signingCertificateSHA256": "a" * 64,
                "appleDeveloperSigned": False,
                "notarized": False,
                "gatekeeperReady": False,
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
            self.assertTrue((output / manifest["package"]).is_file())


if __name__ == "__main__":
    unittest.main()
