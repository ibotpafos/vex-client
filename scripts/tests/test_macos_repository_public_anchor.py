#!/usr/bin/env python3
"""Offline proof that the native verifier loads the committed public P-256 anchor."""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
MODELS = REPO / "macos-native/Sources/VEXNativeMac/Models/VEXModels.swift"
VERIFIER = REPO / "macos-native/Sources/VEXNativeMac/Services/NativeVPNProfileAuthorizationVerifier.swift"
WINDOWS_KEYRING = REPO / "native-windows/packaging/profile-signing-keys.json"
RESOURCE = "native-vpn-profile-public-keys.json"
KEY_ID = "native-profile-p256-v1"
ALGORITHM = "ECDSA_P256_SHA256_DER"
KEYRING_SHA256 = "be66fbec7816879c8cb6bb36fa8947263b53c3cc9f829d969361776163896ec1"
DER_SHA256 = "f194a1a8765d9e5490ade0f5f6df7310e187d8a5f2baeddf39eee0165c4c2289"

# This test deliberately uses only a public committed anchor. The probe creates
# an unrelated ephemeral P-256 key solely to produce a syntactically valid DER
# signature which cannot validate under the repository anchor.
MAIN = r'''import CryptoKit
import Foundation

func rawURL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func report(_ verifier: NativeVPNProfileAuthorizationVerifier, keyID: String, signature: String) {
    let text = "{\"rotation_id\":\"r\",\"activate\":false,\"current_version\":1,\"profile_version\":1,\"profile_digest\":\"d\",\"deadline_at\":\"2030-01-01T00:00:00Z\",\"profile\":{\"authorization\":{\"algorithm\":\"ECDSA_P256_SHA256_DER\",\"key_id\":\"\(keyID)\",\"payload_base64\":\"eA\",\"signature_base64\":\"\(signature)\"}}}"
    do {
        let envelope = try JSONDecoder().decode(PSKRotationCurrentResponse.self, from: Data(text.utf8))
        _ = try verifier.verify(envelope, ownerAccountID: "owner", managedDeviceID: "device", locationID: "location", routingMode: "full_tunnel", now: Date(timeIntervalSince1970: 1_700_000_000))
        print("unexpected-success")
    } catch let failure as NativeVPNProfileAuthorizationVerifier.Failure {
        print("failure=\(failure)")
    } catch { print("unexpected=\(error)") }
}
let ephemeral = P256.Signing.PrivateKey()
let signature = try! ephemeral.signature(for: Data("anchor-probe".utf8)).derRepresentation
let verifier = NativeVPNProfileAuthorizationVerifier.bundled()
report(verifier, keyID: ProcessInfo.processInfo.environment["PROBE_KEY_ID"]!, signature: rawURL(signature))
'''


class MacOSRepositoryPublicAnchorTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        if shutil.which("swiftc") is None:
            self.skipTest("swiftc is required for the offline CryptoKit probe")
        self.keyring_bytes = WINDOWS_KEYRING.read_bytes()
        self.keyring = json.loads(self.keyring_bytes)
        self.assertEqual(hashlib.sha256(self.keyring_bytes).hexdigest(), KEYRING_SHA256)
        entry = self.keyring["keys"][0]
        self.assertEqual((entry["key_id"], entry["algorithm"]), (KEY_ID, ALGORITHM))
        self.der = base64.b64decode(entry["subject_public_key_info_base64"], validate=True)
        self.assertEqual(hashlib.sha256(self.der).hexdigest(), DER_SHA256)

    def build_probe(self, root: pathlib.Path, resource: bytes | None) -> pathlib.Path:
        app = root / "RepositoryAnchorProbe.app"
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        if resource is not None:
            (resources / RESOURCE).write_bytes(resource)
        main = root / "main.swift"
        main.write_text(MAIN)
        probe = macos / "repository-anchor-probe"
        result = subprocess.run(["swiftc", str(MODELS), str(VERIFIER), str(main), "-o", str(probe)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return probe

    def run_probe(self, probe: pathlib.Path, key_id: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(probe)], env={"PROBE_KEY_ID": key_id}, text=True, capture_output=True)

    def test_committed_public_anchor_loads_and_fail_closed_cases_remain_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            known_resource = json.dumps({KEY_ID: base64.b64encode(self.der).decode("ascii")}, separators=(",", ":")).encode()
            cases = {
                "known_anchor_unrelated_valid_der_signature": (known_resource, KEY_ID, "failure=signature"),
                "missing_resource": (None, KEY_ID, "failure=missingTrustAnchor"),
                "malformed_resource": (b"{not-json", KEY_ID, "failure=missingTrustAnchor"),
                "unknown_key": (known_resource, "unknown-key", "failure=malformed"),
            }
            for name, (resource, key_id, expected) in cases.items():
                with self.subTest(name=name):
                    probe = self.build_probe(root / name, resource)
                    result = self.run_probe(probe, key_id)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)
                    self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
