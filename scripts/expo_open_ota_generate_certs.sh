#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOBILE_DIR="${ROOT_DIR}"
CERT_DIR="${CERT_DIR:-${MOBILE_DIR}/certs}"
COMMON_NAME="${COMMON_NAME:-VEX Expo Open OTA}"
VALID_DAYS="${VALID_DAYS:-3650}"

require() {
  local name
  for name in "$@"; do
    if ! command -v "${name}" >/dev/null 2>&1; then
      echo "missing required command: ${name}" >&2
      exit 2
    fi
  done
}

require openssl

mkdir -p "${CERT_DIR}"
umask 077

openssl genrsa -out "${CERT_DIR}/private-key.pem" 2048
openssl rsa -in "${CERT_DIR}/private-key.pem" -pubout -out "${CERT_DIR}/public-key.pem"
openssl req \
  -new \
  -x509 \
  -key "${CERT_DIR}/private-key.pem" \
  -out "${CERT_DIR}/certificate.pem" \
  -days "${VALID_DAYS}" \
  -subj "/CN=${COMMON_NAME}"

echo "Generated Expo Open OTA keys in ${CERT_DIR}"
echo "Commit only ${CERT_DIR}/certificate.pem. Keep private-key.pem and public-key.pem in deployment secrets."
