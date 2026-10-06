import hashlib
import importlib.util
import io
import unittest
import urllib.error
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "receipt", Path(__file__).resolve().parents[1] / "scripts/verify_release_receipt.py"
)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class Response:
    status = 200

    def __init__(self, url, body):
        self.url, self.body = url, body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def read(self):
        return self.body


class Opener:
    def __init__(self, bodies):
        self.bodies = bodies

    def open(self, request, timeout):
        return Response(request.full_url, self.bodies[request.full_url])


class RedirectingOpener(Opener):
    def open(self, request, timeout):
        return Response("https://github.com/redirected", self.bodies[request.full_url])


class RedirectResponseOpener:
    def __init__(self, target, status=302):
        self.target, self.status = target, status

    def open(self, request, timeout):
        raise urllib.error.HTTPError(
            request.full_url,
            self.status,
            "redirect",
            {"Location": self.target},
            io.BytesIO(),
        )


class ReceiptContract(unittest.TestCase):
    def setUp(self):
        self.apk, self.sig = b"apk-bytes", b"signer-report"
        self.release = {
            "platform": "android", "version": "1.0.67", "build": 1006775,
            "download_asset": "Vex-Android-1.0.67-75.apk",
            "assets": [
                {"name": "Vex-Android-1.0.67-75.apk", "sha256": hashlib.sha256(self.apk).hexdigest(), "url": "https://github.com/immutable.apk"},
                {"name": "Vex-Android-1.0.67-75.apk.sig", "sha256": hashlib.sha256(self.sig).hexdigest(), "url": "https://github.com/immutable.apk.sig"},
            ],
        }
        self.apk_url, self.sig_url = receipt.canonical_delivery_urls("https://vexguard.app", self.release)
        self.opener = Opener({self.apk_url: self.apk, self.sig_url: self.sig})
        self.response = {
            "latestVersion": self.release["version"], "latestBuild": self.release["build"],
            "downloadUrl": self.apk_url, "checksumSha256": self.release["assets"][0]["sha256"],
            "signatureUrl": self.sig_url,
        }

    def test_accepts_exact_first_party_immutable_pair_and_bytes(self):
        self.assertTrue(receipt.android_receipt_matches(self.release, self.response, "https://vexguard.app", self.opener))

    def test_rejects_current_github_metadata_before_download(self):
        github = {**self.response, "downloadUrl": self.release["assets"][0]["url"], "signatureUrl": self.release["assets"][1]["url"]}
        self.assertFalse(receipt.android_receipt_matches(self.release, github, "https://vexguard.app", self.opener))

    def test_rejects_wrong_signature_or_tampered_first_party_bytes(self):
        self.assertFalse(receipt.android_receipt_matches(self.release, {**self.response, "signatureUrl": self.apk_url}, "https://vexguard.app", self.opener))
        tampered = Opener({self.apk_url: b"tampered", self.sig_url: self.sig})
        self.assertFalse(receipt.android_receipt_matches(self.release, self.response, "https://vexguard.app", tampered))

    def test_rejects_cross_host_redirect_even_when_bytes_match(self):
        redirected = RedirectingOpener({self.apk_url: self.apk, self.sig_url: self.sig})
        with self.assertRaisesRegex(ValueError, "redirected"):
            receipt.android_receipt_matches(self.release, self.response, "https://vexguard.app", redirected)

    def test_keeps_macos_website_latest_redirect_contract(self):
        target = "https://github.com/ibotpafos/vex-client/releases/download/macos-v1.0.67/Vex.dmg"
        self.assertTrue(
            receipt.website_redirect_matches(
                "https://vexguard.app", "macos", target, RedirectResponseOpener(target)
            )
        )
        self.assertFalse(
            receipt.website_redirect_matches(
                "https://vexguard.app", "macos", target, RedirectResponseOpener("https://example.invalid/file")
            )
        )
