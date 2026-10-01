#!/usr/bin/env python3
"""Offline decision-prefix regressions for explicit macOS signing identities."""
from __future__ import annotations
import os
import pathlib
import shutil
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ("build_native_macos_app.sh", "build_swift_macos_helper.sh")
MARKERS = {
    "build_native_macos_app.sh": 'if [[ ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then',
    "build_swift_macos_helper.sh": "build_arch() {",
}


def decision_copy(source: pathlib.Path, destination: pathlib.Path, security: pathlib.Path) -> None:
    text = source.read_text()
    marker = MARKERS[source.name]
    prefix, found, _ = text.partition(marker)
    assert found, marker
    # Exercise only identity selection. Absolute security references are replaced
    # in this disposable fixture, never in the production source or user keychain.
    prefix = prefix.replace("/usr/bin/security", str(security))
    destination.write_text(prefix + 'printf "identity=%s\\n" "$CODESIGN_IDENTITY"\n')
    destination.chmod(0o755)


def run_prefix(source: pathlib.Path, identity: str | None, local_identity: str | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp:
        temp_path = pathlib.Path(temp)
        fixture_root = temp_path / "fixture"
        script_dir = fixture_root / "scripts"
        script_dir.mkdir(parents=True)
        fake_security = temp_path / "security"
        calls = temp_path / "security.calls"
        fake_security.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_SECURITY_CALLS\"\n"
            "printf '%s\\n' '  1) DISCOVERED (CSSMERR_TP_NOT_TRUSTED) \"Apple Development: Offline Test\"'\n"
        )
        fake_security.chmod(0o755)
        script = script_dir / source.name
        decision_copy(source, script, fake_security)
        if local_identity is not None:
            (fixture_root / ".env.sparkle.local").write_text(
                f"VEX_CODESIGN_IDENTITY={shlex.quote(local_identity)}\n"
            )
        env = os.environ | {"FAKE_SECURITY_CALLS": str(calls), "VEX_LOCAL_SIGNING_DIR": str(temp_path / "no-local-identity")}
        if identity is None:
            env.pop("VEX_CODESIGN_IDENTITY", None)
        else:
            env["VEX_CODESIGN_IDENTITY"] = identity
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True, env=env)
        result.security_calls = calls.read_text().splitlines() if calls.exists() else []  # type: ignore[attr-defined]
        return result


class ExplicitMacOSSigningTests(unittest.TestCase):
    def assert_case(self, source: pathlib.Path, identity: str | None, expected_calls: int, expected_identity: str) -> None:
        result = run_prefix(source, identity)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.security_calls), expected_calls)  # type: ignore[attr-defined]
        self.assertEqual(result.stdout, f"identity={expected_identity}\n")

    def test_explicit_ad_hoc_identity_never_discovers_or_mutates_keychains(self) -> None:
        for name in SCRIPTS:
            with self.subTest(script=name):
                self.assert_case(REPO / "scripts" / name, "-", 0, "-")

    def test_explicit_named_identity_never_discovers(self) -> None:
        for name in SCRIPTS:
            with self.subTest(script=name):
                self.assert_case(REPO / "scripts" / name, "Named Offline Identity", 0, "Named Offline Identity")

    def test_unset_identity_retains_discovery(self) -> None:
        for name in SCRIPTS:
            with self.subTest(script=name):
                self.assert_case(REPO / "scripts" / name, None, 1, "DISCOVERED")

    def test_app_caller_identity_precedes_sparkle_local_default(self) -> None:
        result = run_prefix(REPO / "scripts" / "build_native_macos_app.sh", "Caller Identity", "Local Default Identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.security_calls, [])  # type: ignore[attr-defined]
        self.assertEqual(result.stdout, "identity=Caller Identity\n")


if __name__ == "__main__":
    unittest.main()
