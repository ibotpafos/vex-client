#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-}"
KEYCHAIN_PASSWORD="${VEX_SELF_SIGNED_KEYCHAIN_PASSWORD:-}"
P12_PASSWORD="${VEX_SELF_SIGNED_P12_PASSWORD:-}"
VALID_DAYS="${VEX_SELF_SIGNED_VALID_DAYS:-825}"
APP_COMMON_NAME="${VEX_SELF_SIGNED_APP_COMMON_NAME:-VEX Self-Signed Application}"
INSTALLER_COMMON_NAME="${VEX_SELF_SIGNED_INSTALLER_COMMON_NAME:-VEX Self-Signed Installer}"

if [[ -z "${OUTPUT_DIR}" || -z "${KEYCHAIN_PASSWORD}" || -z "${P12_PASSWORD}" ]]; then
  echo "usage: VEX_SELF_SIGNED_KEYCHAIN_PASSWORD=... VEX_SELF_SIGNED_P12_PASSWORD=... $0 OUTPUT_DIR" >&2
  exit 2
fi
if [[ -e "${OUTPUT_DIR}" ]]; then
  echo "refusing to overwrite existing identity directory: ${OUTPUT_DIR}" >&2
  exit 2
fi

mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"
KEYCHAIN_PATH="${OUTPUT_DIR}/vex-self-signed-release.keychain-db"

write_config() {
  local path="$1"
  local common_name="$2"
  local apple_oid="$3"
  local extended_usage="$4"
  cat >"${path}" <<EOF
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=${common_name}
O=VEX
[extensions]
basicConstraints=critical,CA:true
keyUsage=critical,digitalSignature,keyCertSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
${extended_usage}
${apple_oid}=ASN1:NULL
EOF
}

create_identity() {
  local stem="$1"
  local common_name="$2"
  local apple_oid="$3"
  local extended_usage="$4"
  write_config "${OUTPUT_DIR}/${stem}.cnf" "${common_name}" "${apple_oid}" "${extended_usage}"
  openssl req -new -x509 -newkey rsa:3072 -nodes -days "${VALID_DAYS}" \
    -config "${OUTPUT_DIR}/${stem}.cnf" \
    -keyout "${OUTPUT_DIR}/${stem}.key.pem" \
    -out "${OUTPUT_DIR}/${stem}.cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export \
    -inkey "${OUTPUT_DIR}/${stem}.key.pem" \
    -in "${OUTPUT_DIR}/${stem}.cert.pem" \
    -out "${OUTPUT_DIR}/${stem}.identity.p12" \
    -passout "pass:${P12_PASSWORD}" \
    -name "${common_name}"
  chmod 600 "${OUTPUT_DIR}/${stem}.key.pem" "${OUTPUT_DIR}/${stem}.identity.p12"
}

create_identity application "${APP_COMMON_NAME}" "1.2.840.113635.100.6.1.13" "extendedKeyUsage=codeSigning"
create_identity installer "${INSTALLER_COMMON_NAME}" "1.2.840.113635.100.6.1.14" ""

security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
for stem in application installer; do
  security import "${OUTPUT_DIR}/${stem}.identity.p12" \
    -k "${KEYCHAIN_PATH}" -P "${P12_PASSWORD}" \
    -T /usr/bin/codesign -T /usr/bin/productsign >/dev/null
  security add-trusted-cert -r trustRoot -k "${KEYCHAIN_PATH}" "${OUTPUT_DIR}/${stem}.cert.pem"
done
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}" >/dev/null

app_sha256="$(openssl x509 -in "${OUTPUT_DIR}/application.cert.pem" -outform der | shasum -a 256 | awk '{print $1}')"
installer_sha256="$(openssl x509 -in "${OUTPUT_DIR}/installer.cert.pem" -outform der | shasum -a 256 | awk '{print $1}')"
cat >"${OUTPUT_DIR}/release.env" <<EOF
export VEX_CODESIGN_IDENTITY='${APP_COMMON_NAME}'
export VEX_CODESIGN_KEYCHAIN='${KEYCHAIN_PATH}'
export VEX_CODESIGN_TIMESTAMP='none'
export VEX_INSTALLER_SIGN_IDENTITY='${INSTALLER_COMMON_NAME}'
export VEX_INSTALLER_SIGN_KEYCHAIN='${KEYCHAIN_PATH}'
export VEX_INSTALLER_SIGN_TIMESTAMP='none'
export VEX_SELF_SIGNED_APP_CERT_PATH='${OUTPUT_DIR}/application.cert.pem'
export VEX_SELF_SIGNED_INSTALLER_CERT_PATH='${OUTPUT_DIR}/installer.cert.pem'
export VEX_SELF_SIGNED_APP_CERT_SHA256='${app_sha256}'
export VEX_SELF_SIGNED_INSTALLER_CERT_SHA256='${installer_sha256}'
EOF
chmod 600 "${OUTPUT_DIR}/release.env"

echo "Self-signed release identities created in ${OUTPUT_DIR}"
echo "Keep the directory private and stable; never publish its key or PKCS#12 files."
echo "Application certificate SHA-256: ${app_sha256}"
echo "Installer certificate SHA-256: ${installer_sha256}"
echo "Load non-secret release variables with: source '${OUTPUT_DIR}/release.env'"
