#!/usr/bin/env bash
set -euo pipefail
set +x
expected_input="${1:?Fixed input SHA256 required}"
tag="${2:?Private draft input tag required}"
expected_signer=cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470
bash scripts/verify_android_signing_secret.sh "$expected_signer"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p signed-candidate
gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern input.apk --dir "$work"
printf '%s  %s\n' "$expected_input" "$work/input.apk" | sha256sum -c -
tools="$(find "$ANDROID_HOME/build-tools" -mindepth 2 -maxdepth 2 -name apksigner | sort -V | tail -1)"
[[ -x "$tools" ]] || { echo APKSIGNER_MISSING; exit 2; }
badging="$("$(dirname "$tools")/aapt" dump badging "$work/input.apk")"
grep -q "^package: name='app.vex.updaterqa' versionCode='1' versionName='1'" <<< "$badging"
export KEYSTORE_DEST="$work/store.jks"
python3 - <<'PY'
import base64, os
with open(os.environ['KEYSTORE_DEST'], 'wb') as f:
    f.write(base64.b64decode(os.environ['ANDROID_RELEASE_KEYSTORE_BASE64'], validate=True))
PY
"$tools" sign --ks "$KEYSTORE_DEST" --ks-key-alias "$VEX_UPLOAD_KEY_ALIAS" --ks-pass env:VEX_UPLOAD_STORE_PASSWORD --key-pass env:VEX_UPLOAD_KEY_PASSWORD --out signed-candidate/VEX-Updater-QA.apk "$work/input.apk"
"$tools" verify --verbose --print-certs signed-candidate/VEX-Updater-QA.apk > signed-candidate/signature.txt
grep -q "certificate SHA-256 digest: $expected_signer" signed-candidate/signature.txt
keytool -exportcert -keystore "$KEYSTORE_DEST" -storepass:env VEX_UPLOAD_STORE_PASSWORD -alias "$VEX_UPLOAD_KEY_ALIAS" -file signed-candidate/certificate.der >"$work/export.log" 2>&1
sha256sum signed-candidate/VEX-Updater-QA.apk > signed-candidate/checksum.txt
echo ANDROID_PACKAGE_AND_SIGNER=PASS
