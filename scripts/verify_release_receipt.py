#!/usr/bin/env python3
"""Bounded post-publication website gate; no polling daemon or admin access."""
import argparse
import json
import time
import urllib.request
import urllib.error

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def website_redirect_matches(platform, target):
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(f"https://vexguard.app/downloads/{platform}/latest", method="GET")
    try:
        with opener.open(request, timeout=8):
            return False
    except urllib.error.HTTPError as response:
        return response.code in (302, 303, 307, 308) and response.headers.get("Location") == target

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", required=True)
args = parser.parse_args()
with open(args.manifest) as source:
    release = json.load(source)
asset = next(a for a in release["assets"] if a["name"] == release["download_asset"])
body = json.dumps({"platform": release["platform"], "channel": "stable", "appVersion": "0.0.0", "buildNumber": 0, "apiClientVersion": "web-download", "configSchemaVersion": 1}).encode()
# TODO release receiver activation: production tag publication stays gated until
# the signed webhook receiver and public website routes pass live acceptance.
for attempt in range(18):
    try:
        request = urllib.request.Request("https://vexguard.app/v1/app/update/check", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=8) as response:
            receipt = json.load(response)
        if (receipt.get("latestVersion"), receipt.get("latestBuild"), receipt.get("downloadUrl"), receipt.get("checksumSha256")) == (release["version"], release["build"], asset["url"], asset["sha256"]) and website_redirect_matches(release["platform"], asset["url"]):
            print(json.dumps({"status": "website_verified", "platform": release["platform"], "version": release["version"], "build": release["build"]}))
            break
    except (OSError, ValueError):
        pass
    if attempt == 17:
        raise SystemExit("Published GitHub release has no matching website receipt; prior stable state must be retained/inspected. No forced rollback or republish.")
    time.sleep(5)
