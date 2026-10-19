"""Exercise the release source gate against real, isolated Git checkouts."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "macos_release_sources", Path(__file__).parents[1] / "verify_native_macos_release_sources.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class SourceGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="macos-source-gate-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.client = self.repository(self.root)
        self.server = self.repository(self.root / "vpn-main")
        self.env = {"GITHUB_SHA": self.client, "GITHUB_REF": "refs/heads/main",
                    "VEX_NATIVE_SOURCE_COMMIT": self.client,
                    "VEX_VPN_SOURCE_COMMIT": self.server}

    def repository(self, root):
        root.mkdir(exist_ok=True)
        def git(*args):
            return subprocess.check_output(["git", "-C", str(root), *args],
                                           text=True, stderr=subprocess.DEVNULL).strip()
        git("init", "--quiet")
        (root / "source.txt").write_text(str(root))
        git("add", "source.txt")
        git("-c", "user.name=Source Gate", "-c", "user.email=source-gate@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        return git("rev-parse", "HEAD")

    def verify(self, **changes):
        with patch.dict(os.environ, {**self.env, **changes}, clear=True):
            return gate.verify(self.root)

    def test_exact_pair_is_attested(self):
        result = self.verify()
        self.assertEqual((result["clientCommit"], result["vpnCommit"], result["workflowCommit"]),
                         (self.client, self.server, self.client))
        self.assertTrue(result["clientPinExplicit"] and result["vpnPinExplicit"])

    def test_original_three_input_dispatch_remains_supported(self):
        result = self.verify(VEX_NATIVE_SOURCE_COMMIT="", VEX_VPN_SOURCE_COMMIT="",
                             GITHUB_REF="refs/heads/legacy-manual-release")
        self.assertFalse(result["clientPinExplicit"] or result["vpnPinExplicit"])

    def test_moving_vpn_main_fails(self):
        with self.assertRaisesRegex(ValueError, "VPN main moved"):
            self.verify(VEX_VPN_SOURCE_COMMIT="1" * 40)

    def test_client_checkout_must_be_workflow_source(self):
        with self.assertRaisesRegex(ValueError, "Client checkout"):
            self.verify(GITHUB_SHA="2" * 40, VEX_NATIVE_SOURCE_COMMIT="")

    def test_foreign_client_pin_and_non_main_operator_dispatch_fail(self):
        for change in ({"VEX_NATIVE_SOURCE_COMMIT": "3" * 40},
                       {"GITHUB_REF": "refs/pull/123/head"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(**change)

    def test_short_or_expression_pins_fail(self):
        for value in ("main", "HEAD", "1" * 7, "A" * 40, "1" * 40 + "\n"):
            with self.subTest(pin=value), self.assertRaises(ValueError):
                self.verify(VEX_VPN_SOURCE_COMMIT=value)


if __name__ == "__main__":
    unittest.main()
