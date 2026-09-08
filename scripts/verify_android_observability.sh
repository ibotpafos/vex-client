#!/usr/bin/env bash
set -euo pipefail
set +x

mode="${1:-}"
expected_host="errors.vexguard.app"

case "${mode}" in
  env)
    python3 - "${expected_host}" <<'PY'
import os
import sys
from urllib.parse import urlparse

expected_host = sys.argv[1]
dsn = os.environ.get("EXPO_PUBLIC_SENTRY_DSN", "").strip()
if not dsn:
    print("EXPO_PUBLIC_SENTRY_DSN is required for a production Android release", file=sys.stderr)
    raise SystemExit(2)

parsed = urlparse(dsn)
if (
    parsed.scheme != "https"
    or not parsed.username
    or parsed.password is not None
    or parsed.hostname != expected_host
    or parsed.port is not None
    or parsed.path in ("", "/")
):
    print(
        f"EXPO_PUBLIC_SENTRY_DSN must be an HTTPS Bugsink DSN for {expected_host}",
        file=sys.stderr,
    )
    raise SystemExit(2)
PY
    echo "ANDROID_BUGSINK_ENV=PASS host=${expected_host}"
    ;;
  apk)
    apk_path="${2:-}"
    if [[ -z "${apk_path}" || ! -f "${apk_path}" ]]; then
      echo "usage: $0 apk <path-to-apk>" >&2
      exit 2
    fi
    python3 - "${apk_path}" "${expected_host}" <<'PY'
import re
import sys
import zipfile

apk_path, expected_host = sys.argv[1:]
dsn_pattern = re.compile(
    rb"https://[A-Za-z0-9._~-]+@"
    + re.escape(expected_host.encode("ascii"))
    + rb"/[A-Za-z0-9._~-]+"
)

with zipfile.ZipFile(apk_path) as apk:
    candidates = [
        name
        for name in apk.namelist()
        if re.fullmatch(r"classes\d*\.dex", name)
        or name in {"resources.arsc", "AndroidManifest.xml"}
    ]
    found = any(dsn_pattern.search(apk.read(name)) for name in candidates)

if not found:
    print(
        f"Android release APK is missing Bugsink DSN for {expected_host}",
        file=sys.stderr,
    )
    raise SystemExit(2)
PY
    echo "ANDROID_BUGSINK_APK=PASS host=${expected_host}"
    ;;
  *)
    echo "usage: $0 {env|apk <path-to-apk>}" >&2
    exit 2
    ;;
esac
