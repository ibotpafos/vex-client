#!/usr/bin/env bash
set -euo pipefail
set +x
expected="${1:?Expected production certificate SHA256 is required}"
for name in ANDROID_RELEASE_KEYSTORE_BASE64 VEX_UPLOAD_STORE_PASSWORD VEX_UPLOAD_KEY_ALIAS VEX_UPLOAD_KEY_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then echo "MISSING_SECRET:$name"; exit 2; fi
done
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export KEYSTORE_DEST="$work/store.jks"
python3 - <<'PY'
import base64, os
with open(os.environ['KEYSTORE_DEST'], 'wb') as f:
    f.write(base64.b64decode(os.environ['ANDROID_RELEASE_KEYSTORE_BASE64'], validate=True))
PY
if ! keytool -exportcert -keystore "$KEYSTORE_DEST" -storepass:env VEX_UPLOAD_STORE_PASSWORD -alias "$VEX_UPLOAD_KEY_ALIAS" -file "$work/cert.der" >"$work/keytool.log" 2>&1; then
  echo KEYSTORE_READ_FAILED; exit 1
fi
actual="$(openssl dgst -sha256 "$work/cert.der" | awk '{print $NF}')"
if [[ "$actual" != "$expected" ]]; then
  echo CERTIFICATE_MISMATCH; echo "certificate_sha256=$actual"; exit 1
fi
printf 'VEX signing custody verification fixture\n' > "$work/challenge.txt"
jar cf "$work/challenge.jar" -C "$work" challenge.txt
if ! jarsigner -keystore "$KEYSTORE_DEST" -storepass:env VEX_UPLOAD_STORE_PASSWORD -keypass:env VEX_UPLOAD_KEY_PASSWORD "$work/challenge.jar" "$VEX_UPLOAD_KEY_ALIAS" >"$work/sign.log" 2>&1; then
  echo PRIVATE_KEY_SIGN_FAILED; exit 1
fi
if ! jarsigner -verify "$work/challenge.jar" >"$work/verify.log" 2>&1 || ! grep -q 'jar verified\.' "$work/verify.log"; then
  echo SIGNATURE_VERIFICATION_FAILED; exit 1
fi
echo "certificate_sha256=$actual"
echo CERTIFICATE_MATCH=PASS
echo PRIVATE_KEY_SIGN_AND_VERIFY=PASS
