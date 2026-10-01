#!/usr/bin/env bash
set -euo pipefail
set +x

# Validate the same approved project for native and bundled JavaScript SDKs.
# Never put the ingestion key in output, including parser/archive errors.
python3 - "$@" <<'PYTHON'
import os
import re
import sys
import zipfile
from urllib.parse import urlsplit

HOST = "errors.vexguard.app"

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)

args = sys.argv[1:]
if args != ["env"] and not (len(args) == 2 and args[0] == "apk"):
    fail("usage: verify_android_observability.sh {env|apk <path-to-apk>}")
dsn = os.environ.get("EXPO_PUBLIC_SENTRY_DSN", "").strip()
if not dsn:
    fail("EXPO_PUBLIC_SENTRY_DSN is required for a production Android release")
try:
    parsed = urlsplit(dsn)
    valid = (
        parsed.scheme == "https"
        and parsed.hostname == HOST
        and parsed.password is None
        and parsed.port is None
        and re.fullmatch(r"[A-Za-z0-9._~-]+", parsed.username or "")
        and re.fullmatch(r"/[1-9][0-9]*", parsed.path)
        and not parsed.query
        and not parsed.fragment
        and dsn == f"https://{parsed.username}@{HOST}{parsed.path}"
    )
except ValueError:
    valid = False
if not valid:
    fail(f"EXPO_PUBLIC_SENTRY_DSN must be a canonical HTTPS Bugsink DSN for {HOST}")
if args[0] == "env":
    print(f"ANDROID_BUGSINK_ENV=PASS host={HOST}")
    raise SystemExit(0)
expected = re.compile(re.escape(dsn.encode("ascii")) + rb"(?![0-9])")
try:
    with zipfile.ZipFile(args[1]) as apk:
        # DEX carries BuildConfig; Expo's Hermes/JS asset carries public env.
        # Either alone leaves one of the SDKs unconfigured.
        native = any(expected.search(apk.read(n)) for n in apk.namelist()
                     if re.fullmatch(r"classes[0-9]*\.dex", n))
        javascript = any(expected.search(apk.read(n)) for n in apk.namelist()
                         if n in {"assets/index.android.bundle", "assets/index.android.hbc"})
except (OSError, zipfile.BadZipFile, RuntimeError, EOFError, ValueError):
    fail("Android release APK cannot be read as a valid archive")
if not native or not javascript:
    fail(f"Android release APK is missing the approved Bugsink DSN in "
         f"native or JavaScript SDK configuration for {HOST}")
print(f"ANDROID_BUGSINK_APK=PASS host={HOST} native=present javascript=present")
PYTHON
