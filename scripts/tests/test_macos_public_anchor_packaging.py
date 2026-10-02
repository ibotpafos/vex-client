#!/usr/bin/env python3
"""Offline runtime fixture for explicit native macOS public-anchor packaging."""
from __future__ import annotations

import base64
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILDER = REPO / "scripts" / "build_native_macos_app.sh"
RESOURCE = "native-vpn-profile-public-keys.json"


class MacOSPublicAnchorPackagingTests(unittest.TestCase):
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
            path.write_bytes(b"fixture")
        return app

    def public_anchor(self, root: pathlib.Path, curve: str = "prime256v1") -> str:
        private = root / f"{curve}.pem"
        public = root / f"{curve}.der"
        subprocess.run(["openssl", "ecparam", "-name", curve, "-genkey", "-noout", "-out", str(private)], check=True, capture_output=True)
        subprocess.run(["openssl", "ec", "-in", str(private), "-pubout", "-outform", "DER", "-out", str(public)], check=True, capture_output=True)
        return base64.b64encode(public.read_bytes()).decode("ascii")

    def run_fixture(self, app: pathlib.Path, source: pathlib.Path | None, timeout: float = 5) -> subprocess.CompletedProcess[str]:
        fake_bin = app.parent / "fake-bin"
        fake_bin.mkdir()
        codesign_log = fake_bin / "codesign.log"
        helper_log = fake_bin / "helper.log"
        for name, body in {
            "codesign": '#!/bin/sh\nprintf "%s|%s\\n" "$*" "$(test -f "${VEX_EXPECTED_RESOURCE}" && echo resource-present || echo resource-absent)" >> "$CODESIGN_LOG"\n',
            "security": '#!/bin/sh\nprintf security >> "$HELPER_LOG"\n',
            "vex-helper": '#!/bin/sh\nprintf helper >> "$HELPER_LOG"\n',
        }.items():
            path = fake_bin / name
            path.write_text(body)
            path.chmod(0o755)
        env = os.environ | {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "CODESIGN_LOG": str(codesign_log),
            "HELPER_LOG": str(helper_log),
            "VEX_EXPECTED_RESOURCE": str(app / "Contents/Resources" / RESOURCE),
            "VEX_MACOS_SIGNING_TEST_ONLY": "1",
            "VEX_MACOS_SIGNING_TEST_APP_DIR": str(app),
            "VEX_CODESIGN_IDENTITY": "Unit Test Signing Identity",
            "VEX_CODESIGN_TIMESTAMP": "none",
        }
        if source is not None:
            env["VEX_NATIVE_VPN_PROFILE_PUBLIC_KEYS_FILE"] = str(source)
        result = subprocess.run(["bash", str(BUILDER)], text=True, capture_output=True, env=env, timeout=timeout)
        result.codesign_log = codesign_log.read_text().splitlines() if codesign_log.exists() else []  # type: ignore[attr-defined]
        result.helper_log = helper_log.read_text() if helper_log.exists() else ""  # type: ignore[attr-defined]
        return result

    def test_explicit_p256_resource_is_copied_before_signing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "anchors.json"
            source.write_text(json.dumps({"release-p256": self.public_anchor(root)}, separators=(",", ":")))
            app = self.make_app(root)
            result = self.run_fixture(app, source)
            resource = app / "Contents/Resources" / RESOURCE
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(resource.read_bytes(), source.read_bytes())
            self.assertTrue(result.codesign_log, "expected fake codesign invocations")  # type: ignore[attr-defined]
            self.assertTrue(all(line.endswith("|resource-present") for line in result.codesign_log))  # type: ignore[attr-defined]
            self.assertEqual(result.helper_log, "")  # type: ignore[attr-defined]

    def test_default_does_not_bundle_fixture_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(pathlib.Path(temporary))
            result = self.run_fixture(app, None)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((app / "Contents/Resources" / RESOURCE).exists())

    def test_invalid_anchor_inputs_fail_before_signing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            p256 = self.public_anchor(root)
            wrong_curve = self.public_anchor(root, "secp384r1")
            invalid_point_der = bytearray(base64.b64decode(p256))
            invalid_point_der[-1] ^= 1  # SPKI prefix/length remain P-256-shaped, point does not.
            invalid_point = base64.b64encode(invalid_point_der).decode("ascii")
            cases: dict[str, bytes] = {
                "malformed": b"{not json", "wrongcurve": json.dumps({"id": wrong_curve}).encode(),
                "invalidpoint": json.dumps({"id": invalid_point}).encode(),
                # The one-byte-over-limit input exercises the bounded 64KiB+1 FD read.
                "oversize": b" " * (64 * 1024 + 1),
                "duplicate": ('{"id":"%s","id":"%s"}' % (p256, p256)).encode(),
            }
            for name, contents in cases.items():
                with self.subTest(name=name):
                    source = root / f"{name}.json"
                    source.write_bytes(contents)
                    app = self.make_app(root / name)
                    result = self.run_fixture(app, source)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stderr.strip(), "Invalid native VPN profile public-key resource")
                    self.assertNotIn(str(source), result.stderr)
                    self.assertEqual(result.codesign_log, [])  # type: ignore[attr-defined]
            # This actual symlink path must fail at O_NOFOLLOW before fake signing.
            target = root / "valid.json"
            target.write_text(json.dumps({"id": p256}))
            symlink = root / "symlink.json"
            symlink.symlink_to(target)
            app = self.make_app(root / "symlink")
            result = self.run_fixture(app, symlink)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.codesign_log, [])  # type: ignore[attr-defined]
            directory = root / "directory-input"
            directory.mkdir()
            app = self.make_app(root / "directory")
            result = self.run_fixture(app, directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.codesign_log, [])  # type: ignore[attr-defined]
            fifo = root / "anchor-input.fifo"
            os.mkfifo(fifo)
            app = self.make_app(root / "fifo")
            result = self.run_fixture(app, fifo, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.codesign_log, [])  # type: ignore[attr-defined]


if __name__ == "__main__":
    unittest.main()
