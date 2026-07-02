#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VEX_NATIVE_VERSION:-}"
BUILD="${VEX_NATIVE_BUILD:-}"

if [[ -z "${VERSION}" ]]; then
  echo "Set VEX_NATIVE_VERSION, for example VEX_NATIVE_VERSION=0.1.1" >&2
  exit 1
fi

if [[ -z "${BUILD}" || ! "${BUILD}" =~ ^[0-9]+$ ]]; then
  echo "Set numeric VEX_NATIVE_BUILD, for example VEX_NATIVE_BUILD=2" >&2
  exit 1
fi

if [[ "${VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS:-0}" == "1" ]]; then
  echo "Internal release cannot use ephemeral Sparkle keys. Use a stable VEX_SPARKLE_PUBLIC_ED_KEY and VEX_SPARKLE_PRIVATE_ED_KEY_FILE." >&2
  exit 2
fi

export VEX_NATIVE_VERSION="${VERSION}"
export VEX_NATIVE_BUILD="${BUILD}"
export VEX_SPARKLE_PRODUCTION="${VEX_SPARKLE_PRODUCTION:-1}"
export VEX_NATIVE_DISTRIBUTION_MODE="${VEX_NATIVE_DISTRIBUTION_MODE:-internal}"
export VEX_NATIVE_REQUIRE_DEVELOPER_ID=0

bash "${ROOT_DIR}/scripts/build_native_macos_app.sh"
bash "${ROOT_DIR}/scripts/build_native_macos_pkg.sh"
bash "${ROOT_DIR}/scripts/build_native_macos_sparkle_release.sh"

pkg_path="$(ls -t "${ROOT_DIR}/macos-native/build/pkg/"*.pkg | head -n 1)"
VEX_NATIVE_PKG_PATH="${pkg_path}" \
  VEX_NATIVE_PRODUCTION=1 \
  VEX_NATIVE_DISTRIBUTION_MODE=internal \
  bash "${ROOT_DIR}/scripts/native_macos_production_preflight.sh"

echo "Internal macOS release ready:"
echo "  app: ${ROOT_DIR}/macos-native/build/VEXNativeMac.app"
echo "  pkg: ${pkg_path}"
echo "  sparkle: ${ROOT_DIR}/macos-native/build/sparkle-release/archives"
