#!/usr/bin/env bash
set -euo pipefail

# Builds the modern AmneziaWG 3.1 userspace toolchain for macOS (universal
# arm64 + x86_64) from the pinned refs and installs it into HelperResources,
# which build_native_macos_app.sh bundles into the helper resources dir.
#
# Usage:
#   scripts/build_amneziawg_macos_binaries.sh [--skip-bootstrap]
#
# Requirements: Xcode Command Line Tools, Go (any recent), `make`, `lipo`.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"
helper_resource_dir="${PACKAGE_DIR:-"${root_dir}/macos-native/HelperResources"}"
go_ref="b5928efb6ca19f0153958460c3d141f04abc5c2e"
tools_ref="ee0f0a9aa34ff0a0da4b3433b9512781cfe02843"

skip_bootstrap=0
if [[ "${1:-}" == "--skip-bootstrap" ]]; then skip_bootstrap=1; fi

# 1. Checkouts must be at the pinned official refs.
if [[ "${skip_bootstrap}" == "0" ]]; then
  "${root_dir}/scripts/bootstrap_amneziawg_macos.sh"
fi

go_actual="$(cd "${external_dir}/amneziawg-go" && git rev-parse HEAD 2>/dev/null || true)"
tools_actual="$(cd "${external_dir}/amneziawg-tools" && git rev-parse HEAD 2>/dev/null || true)"
if [[ "${go_actual}" != "${go_ref}" || "${tools_actual}" != "${tools_ref}" ]]; then
  echo "error: external checkouts are not at pinned refs" >&2
  echo "  amneziawg-go   expected ${go_ref} got ${go_actual:-<missing>}" >&2
  echo "  amneziawg-tools expected ${tools_ref} got ${tools_actual:-<missing>}" >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

echo "== building amneziawg-go (AmneziaWG 3.1) universal =="
(cd "${external_dir}/amneziawg-go"
  GOARCH=arm64 go build -o "${scratch}/amneziawg-go-arm64" .
  GOARCH=amd64 go build -o "${scratch}/amneziawg-go-amd64" .
)
lipo -create -output "${scratch}/amneziawg-go-universal" \
  "${scratch}/amneziawg-go-arm64" "${scratch}/amneziawg-go-amd64"

echo "== building amneziawg-tools (awg v3.1.20260828) universal =="
(
  cd "${external_dir}/amneziawg-tools/src"
  make clean >/dev/null
  make wg >/dev/null
  cp wg "${scratch}/awg-arm64"
  make clean >/dev/null
  make wg CC="cc -arch x86_64" >/dev/null
  cp wg "${scratch}/awg-amd64"
  make clean >/dev/null
)
lipo -create -output "${scratch}/awg-universal" \
  "${scratch}/awg-arm64" "${scratch}/awg-amd64"

echo "== built binaries =="
"${scratch}/awg-universal" --version
"${scratch}/amneziawg-go-universal" --version | head -n 1
lipo -info "${scratch}/awg-universal"
lipo -info "${scratch}/amneziawg-go-universal"

echo "== installing into HelperResources =="
mkdir -p "${helper_resource_dir}"
cp "${scratch}/awg-universal" "${helper_resource_dir}/awg"
cp "${scratch}/amneziawg-go-universal" "${helper_resource_dir}/amneziawg-go"
chmod 755 "${helper_resource_dir}/awg" "${helper_resource_dir}/amneziawg-go"
echo "  awg           md5=$(md5 -q "${helper_resource_dir}/awg")  $(shasum -a 256 "${helper_resource_dir}/awg" | awk '{print $1}')"
echo "  amneziawg-go  md5=$(md5 -q "${helper_resource_dir}/amneziawg-go")  $(shasum -a 256 "${helper_resource_dir}/amneziawg-go" | awk '{print $1}')"
echo
echo "done. HelperResources now carries the pinned AmneziaWG 3.1 toolchain."
