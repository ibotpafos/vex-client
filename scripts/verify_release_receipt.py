#!/usr/bin/env python3
"""Fail closed unless Android metadata is consumable by installed legacy clients.

GitHub release URLs remain immutable provenance in ``vex-release.json``. Android
clients before the first-party delivery migration accept only vexguard.app, so
this gate verifies the separately mirrored immutable files returned by the API.
"""
import argparse
import hashlib
import json
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

DEFAULT_BASE_URL = "https://vexguard.app"
LEGACY_ANDROID_VERSION = "1.0.65"
LEGACY_ANDROID_BUILD = 1006573


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def canonical_delivery_urls(base_url, release):
    """Return immutable first-party APK and signer-report URLs."""
    name = str(release["download_asset"])
    if release.get("platform") != "android" or not name.endswith(".apk"):
        raise ValueError("first-party Android receipt requires an APK download asset")
    base = base_url.rstrip("/")
    return f"{base}/downloads/{name}", f"{base}/downloads/{name}.sig"


def asset_by_name(release, name):
    matches = [asset for asset in release["assets"] if asset.get("name") == name]
    if len(matches) != 1 or not isinstance(matches[0].get("sha256"), str):
        raise ValueError(f"release manifest lacks one hashed asset: {name}")
    return matches[0]


def fetch_exact(url, opener=None):
    """Read HTTPS bytes without accepting a redirect or origin change."""
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.params or parsed.query or parsed.fragment:
        raise ValueError("delivery URL must be a clean HTTPS URL")
    opener = opener or urllib.request.build_opener(NoRedirect())
    with opener.open(urllib.request.Request(url, method="GET"), timeout=8) as response:
        if response.geturl() != url:
            raise ValueError("delivery URL redirected")
        if getattr(response, "status", response.getcode()) != 200:
            raise ValueError("delivery URL did not return 200")
        return response.read()


def website_redirect_matches(base_url, platform, target, opener=None):
    """Keep the established non-Android website-download route contract."""
    opener = opener or urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/downloads/{platform}/latest", method="GET"
    )
    try:
        with opener.open(request, timeout=8):
            return False
    except urllib.error.HTTPError as response:
        try:
            return response.code in (302, 303, 307, 308) and response.headers.get("Location") == target
        finally:
            response.close()


def android_receipt_matches(release, receipt, base_url, opener=None):
    apk_url, signature_url = canonical_delivery_urls(base_url, release)
    apk = asset_by_name(release, release["download_asset"])
    signature = asset_by_name(release, release["download_asset"] + ".sig")
    expected = (release["version"], release["build"], apk_url, apk["sha256"], signature_url)
    actual = (receipt.get("latestVersion"), receipt.get("latestBuild"), receipt.get("downloadUrl"), receipt.get("checksumSha256"), receipt.get("signatureUrl"))
    if actual != expected:
        return False
    return hashlib.sha256(fetch_exact(apk_url, opener)).hexdigest() == apk["sha256"] and hashlib.sha256(fetch_exact(signature_url, opener)).hexdigest() == signature["sha256"]


def update_receipt(base_url, release):
    if release.get("platform") == "android":
        body = {"platform": "android", "channel": "production", "appVersion": LEGACY_ANDROID_VERSION,
                "buildNumber": LEGACY_ANDROID_BUILD, "apiClientVersion": "legacy-android-preflight", "configSchemaVersion": 1}
    else:
        body = {"platform": release["platform"], "channel": "stable", "appVersion": "0.0.0", "buildNumber": 0,
                "apiClientVersion": "web-download", "configSchemaVersion": 1}
    request = urllib.request.Request(base_url.rstrip("/") + "/v1/app/update/check", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    args = parser.parse_args()
    with open(args.manifest, encoding="utf-8") as source:
        release = json.load(source)
    # TODO: Add a signed, idempotent publisher that mirrors the verified Android
    # APK/.sig and atomically updates API metadata before this read-only gate.
    for attempt in range(18):
        try:
            if release.get("platform") == "android":
                verified = android_receipt_matches(release, update_receipt(args.base_url, release), args.base_url)
            else:
                asset = asset_by_name(release, release["download_asset"])
                response = update_receipt(args.base_url, release)
                verified = (
                    (response.get("latestVersion"), response.get("latestBuild"), response.get("downloadUrl"), response.get("checksumSha256"))
                    == (release["version"], release["build"], asset.get("url"), asset["sha256"])
                    and website_redirect_matches(args.base_url, release["platform"], asset["url"])
                )
            if verified:
                print(json.dumps({"status": "website_verified", "platform": release["platform"], "version": release["version"], "build": release["build"]}))
                return
        except (OSError, ValueError, KeyError, urllib.error.HTTPError):
            pass
        if attempt == 17:
            raise SystemExit("Published release has no matching first-party immutable Android receipt; retain prior stable state and inspect the mirror/metadata. No forced rollback or republish.")
        time.sleep(5)


if __name__ == "__main__":
    main()
