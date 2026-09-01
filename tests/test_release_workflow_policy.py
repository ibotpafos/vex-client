import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowPolicyTest(unittest.TestCase):
    def test_native_reliability_ci_covers_awg3_recovery_targets(self) -> None:
        workflow = (WORKFLOWS / "native-reliability-ci.yml").read_text()
        for required in (
            "pull_request:",
            "push:",
            "workflow_dispatch:",
            "actions/setup-java@v4",
            "java-version: \"17\"",
            "npm run android:bootstrap",
            ":app:testDebugUnitTest",
            "VpnNetworkRecoveryTest",
            "swift build --package-path macos-native --target VEXNativeMac",
            "NativeParityModelTests",
            "/Applications/Xcode_26.3.app/Contents/Developer",
            "npm run test:unit",
            "npm run typecheck",
            "npm run lint",
            "npm run test:awg-upstream",
        ):
            self.assertIn(required, workflow)

    def test_windows_workflow_job_conditions_do_not_reference_secrets(self) -> None:
        workflow = (WORKFLOWS / "native-windows-ci.yml").read_text()
        package_job = workflow.split("  package_release:", 1)[1]
        condition = package_job.split("    runs-on:", 1)[0]
        self.assertNotIn("secrets.", condition)
        self.assertIn("github.event_name == 'workflow_dispatch'", condition)

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

    def test_native_macos_self_signed_release_workflow_is_fail_closed(self) -> None:
        workflow = (WORKFLOWS / "native-macos-release.yml").read_text()
        for required in (
            "workflow_dispatch:",
            "VEX_MACOS_APPLICATION_P12_BASE64",
            "VEX_MACOS_APPLICATION_P12_PASSWORD",
            "VEX_SELF_SIGNED_APP_CERT_SHA256",
            "VEX_SPARKLE_PRIVATE_ED_KEY_BASE64",
            "VEX_SPARKLE_PUBLIC_ED_KEY",
            "VEX_RELEASE_REPOSITORY_TOKEN",
            "VEX_NATIVE_PRODUCTION: \"1\"",
            "VEX_NATIVE_SIGNING_MODE: self-signed",
            "VEX_NATIVE_REQUIRE_DEVELOPER_ID: \"0\"",
            "VEX_NATIVE_BUILD_PKG: \"0\"",
            "VEX_NOTARIZE: \"0\"",
            "subject=issuer",
            "security add-trusted-cert -r trustRoot -p codeSign",
            "security delete-keychain",
            "if: always()",
            "actions/upload-artifact@v4",
        ):
            self.assertIn(required, workflow)

        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertLess(
            workflow.index("- name: Validate release inputs"),
            workflow.index("- name: Checkout production downloads repository"),
        )
        self.assertNotIn("VEX_NOTARY_APPLE_ID", workflow)
        self.assertNotIn("VEX_MACOS_INSTALLER_P12_BASE64", workflow)

    def test_autonomous_release_preserves_self_signed_production_contract(self) -> None:
        autonomous = (ROOT / "scripts" / "release_native_macos_autonomous.sh").read_text()
        internal = (ROOT / "scripts" / "build_native_macos_internal_release.sh").read_text()
        self.assertIn("export VEX_NATIVE_PRODUCTION=1", autonomous)
        self.assertIn("export VEX_NATIVE_SIGNING_MODE=self-signed", autonomous)
        self.assertIn("export VEX_NATIVE_REQUIRE_DEVELOPER_ID=0", autonomous)
        self.assertIn("export VEX_NATIVE_BUILD_PKG=0", autonomous)
        self.assertIn("export VEX_NOTARIZE=0", autonomous)
        self.assertIn('VEX_NATIVE_PRODUCTION="${VEX_NATIVE_PRODUCTION}"', internal)
        self.assertIn('VEX_NATIVE_REQUIRE_DEVELOPER_ID="${VEX_NATIVE_REQUIRE_DEVELOPER_ID}"', internal)
        self.assertIn('if [[ "${VEX_NATIVE_BUILD_PKG:-1}" == "1" ]]', internal)

    def test_internal_release_preserves_production_preflight_flags(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            checkout = Path(temp_dir) / "checkout"
            scripts = checkout / "scripts"
            pkg_dir = checkout / "macos-native" / "build" / "pkg"
            scripts.mkdir(parents=True)
            pkg_dir.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts" / "build_native_macos_internal_release.sh", scripts)
            for name in (
                "build_native_macos_app.sh",
                "build_native_macos_pkg.sh",
                "build_native_macos_sparkle_release.sh",
            ):
                path = scripts / name
                path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n")
                path.chmod(0o755)
            (pkg_dir / "fixture.pkg").write_bytes(b"fixture")
            preflight = scripts / "native_macos_production_preflight.sh"
            preflight.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n"
                "printf '%s|%s|%s|%s\\n' \"$VEX_NATIVE_PRODUCTION\" "
                "\"$VEX_NATIVE_REQUIRE_DEVELOPER_ID\" \"$VEX_NATIVE_DISTRIBUTION_MODE\" "
                "\"$VEX_NATIVE_SIGNING_MODE\" "
                '> \"$CAPTURE_PATH\"\n'
            )
            preflight.chmod(0o755)
            capture = checkout / "captured.txt"
            env = os.environ.copy()
            env.update(
                VEX_NATIVE_VERSION="9.9.9",
                VEX_NATIVE_BUILD="999",
                VEX_NATIVE_PRODUCTION="1",
                VEX_NATIVE_REQUIRE_DEVELOPER_ID="0",
                VEX_NATIVE_DISTRIBUTION_MODE="self-signed",
                VEX_NATIVE_SIGNING_MODE="self-signed",
                VEX_NATIVE_BUILD_PKG="0",
                CAPTURE_PATH=str(capture),
            )
            subprocess.run(
                ["bash", str(scripts / "build_native_macos_internal_release.sh")],
                check=True,
                cwd=checkout,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(capture.read_text(), "1|0|self-signed|self-signed\n")

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
