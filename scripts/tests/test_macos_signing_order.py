#!/usr/bin/env python3
"""Offline regression coverage for explicit inside-out native macOS signing."""
from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILDER = REPO / "scripts" / "build_native_macos_app.sh"


class MacOSSigningOrderTests(unittest.TestCase):
    def make_app(self, root: pathlib.Path) -> pathlib.Path:
        app = root / "VEXNativeMac.app"
        for relative in (
            "Contents/Resources/resources/awg",
            "Contents/Resources/resources/amneziawg-go",
            "Contents/Resources/resources/vex-helper",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
            "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
            "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
        ):
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"test")
        return app

    def run_signing(self, app: pathlib.Path, fail_on: str | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            fake_bin = pathlib.Path(temp)
            log = fake_bin / "codesign.log"
            fake = fake_bin / "codesign"
            fake.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$CODESIGN_LOG\"\n"
                "case \"$*\" in *\"${CODESIGN_FAIL_ON:-__never__}\"*) exit 73;; esac\n"
            )
            fake.chmod(0o755)
            env = os.environ | {
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "CODESIGN_LOG": str(log),
                "CODESIGN_FAIL_ON": fail_on or "__never__",
                "VEX_MACOS_SIGNING_TEST_ONLY": "1",
                "VEX_MACOS_SIGNING_TEST_APP_DIR": str(app),
                "VEX_CODESIGN_IDENTITY": "Unit Test Signing Identity",
                "VEX_CODESIGN_TIMESTAMP": "none",
            }
            result = subprocess.run(["bash", str(BUILDER)], text=True, capture_output=True, env=env)
            result.codesign_log = log.read_text().splitlines() if log.exists() else []  # type: ignore[attr-defined]
            return result

    def test_generated_plist_disables_automatic_install_by_default(self) -> None:
        source = BUILDER.read_text()
        self.assertIn("<key>SUEnableAutomaticChecks</key>\n  <true/>", source)
        self.assertIn("<key>SUAllowsAutomaticUpdates</key>\n  <true/>", source)
        self.assertIn("<key>SUAutomaticallyUpdate</key>\n  <false/>", source)

    def test_nested_sparkle_code_is_signed_before_framework_and_app(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = self.make_app(pathlib.Path(temp))
            result = self.run_signing(app)
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = [line for line in result.codesign_log if "--force --options runtime --sign" in line]  # type: ignore[attr-defined]
        paths = [line.rsplit(" ", 1)[1] for line in signed]
        framework = str(app / "Contents/Frameworks/Sparkle.framework")
        self.assertNotIn("--deep", "\n".join(signed))
        self.assertEqual(paths[-2:], [framework, str(app)])
        for nested in ("Autoupdate", "/Sparkle", "Updater.app", "Downloader.xpc", "Installer.xpc"):
            self.assertLess(next(i for i, path in enumerate(paths) if nested in path), len(paths) - 2)
        self.assertIn(f"--verify --deep --strict {app}", result.codesign_log[-1])  # type: ignore[attr-defined]

    def test_signing_failure_stops_before_framework_and_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            app = self.make_app(pathlib.Path(temp))
            result = self.run_signing(app, "Installer.xpc/Contents/MacOS/Installer")
        self.assertEqual(result.returncode, 73)
        log = "\n".join(result.codesign_log)  # type: ignore[attr-defined]
        self.assertNotIn("--force --options runtime --sign " + str(app / "Contents/Frameworks/Sparkle.framework"), log)
        self.assertNotIn("--force --options runtime --sign " + str(app) + "\n", log)


if __name__ == "__main__":
    unittest.main()
