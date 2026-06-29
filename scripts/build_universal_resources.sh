#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/scripts/local_release_cache_bootstrap.sh"

AMNEZIA_DIR="${ROOT_DIR}/external/amnezia"
TAURI_RESOURCES_DIR="${ROOT_DIR}/src-tauri/resources"
STAMP_DIR="${ROOT_DIR}/src-tauri/.vex-stamps"
AMNEZIAWG_GO_STAMP="${STAMP_DIR}/amneziawg-go.sha256"
AWG_STAMP="${STAMP_DIR}/awg.sha256"
ENABLE_UPX="${ENABLE_UPX:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
HOST_ONLY="${HOST_ONLY:-0}"

# Auto-detect host arch if HOST_ONLY is enabled
GOARCH=""
CARCH=""
if [[ "${HOST_ONLY}" == "1" ]]; then
  HOST_ARCH="$(uname -m)"
  case "${HOST_ARCH}" in
    x86_64|amd64)
      GOARCH="amd64"
      CARCH="x86_64"
      ;;
    arm64|aarch64)
      GOARCH="arm64"
      CARCH="arm64"
      ;;
    *)
      # Fallback to universal if architecture is unknown
      HOST_ONLY=0
      ;;
  esac
fi

mkdir -p "${TAURI_RESOURCES_DIR}"
mkdir -p "${STAMP_DIR}"

"${ROOT_DIR}/scripts/bootstrap_amneziawg_macos.sh"

tree_hash() {
  local label="$1"
  local dir="$2"
  shift 2
  {
    printf '%s\n' "${label}"
    find "${dir}" -type f "$@" -print 2>/dev/null
  } | LC_ALL=C sort -u | while IFS= read -r path; do
    if [[ -f "${path}" ]]; then
      shasum -a 256 "${path}"
    else
      printf '%s\n' "${path}"
    fi
  done | shasum -a 256 | awk '{print $1}'
  return 0
}

is_current() {
  local output="$1"
  local stamp="$2"
  local hash="$3"
  [[ "${FORCE_REBUILD}" == "1" ]] && return 1
  [[ -x "${output}" && -f "${stamp}" ]] || return 1
  [[ "$(cat "${stamp}")" == "${hash}" ]]
}

echo "== Сборка amneziawg-go ==="
amneziawg_go_hash="$(tree_hash "amneziawg-go-v3 ENABLE_UPX=${ENABLE_UPX} HOST_ONLY=${HOST_ONLY} GOARCH=${GOARCH:-universal}" "${AMNEZIA_DIR}/amneziawg-go" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -name 'Makefile' \))"
if is_current "${TAURI_RESOURCES_DIR}/amneziawg-go" "${AMNEZIAWG_GO_STAMP}" "${amneziawg_go_hash}"; then
  echo "  amneziawg-go актуален, пропускаю сборку."
else
  cd "${AMNEZIA_DIR}/amneziawg-go"
  if [[ "${HOST_ONLY}" == "1" ]]; then
    echo "  [1/2] Компиляция amneziawg-go для хост-архитектуры (darwin/${GOARCH})...."
    rm -f "${TAURI_RESOURCES_DIR}/amneziawg-go"
    CGO_ENABLED=0 GOOS=darwin GOARCH="${GOARCH}" go build -trimpath -ldflags="-s -w" -o "${TAURI_RESOURCES_DIR}/amneziawg-go" .
    if [[ "${ENABLE_UPX}" == "1" ]] && command -v upx >/dev/null 2>&1; then
      echo "  [2/2] Сжатие бинарника с помощью UPX..."
      upx --best --lzma --force-macos "${TAURI_RESOURCES_DIR}/amneziawg-go" >/dev/null || true
    fi
  else
    echo "  [1/4] Компиляция amneziawg-go (darwin/arm64 + darwin/amd64)..."
    rm -f "${TAURI_RESOURCES_DIR}/amneziawg-go"
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o amneziawg-go-arm64 . &
    pid_arm="$!"
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o amneziawg-go-amd64 . &
    pid_x64="$!"
    wait "${pid_arm}"
    wait "${pid_x64}"

    echo "  [3/4] Сжатие бинарников с помощью UPX..."
    if [[ "${ENABLE_UPX}" == "1" ]] && command -v upx >/dev/null 2>&1; then
      upx --best --lzma --force-macos amneziawg-go-arm64 amneziawg-go-amd64 >/dev/null || true
    else
      echo "  UPX пропущен (ENABLE_UPX=1 включает сжатие)."
    fi

    echo "  [4/4] Объединение в Universal Binary..."
    lipo -create amneziawg-go-arm64 amneziawg-go-amd64 -output "${TAURI_RESOURCES_DIR}/amneziawg-go"
    rm -f amneziawg-go-arm64 amneziawg-go-amd64
  fi
  printf '%s\n' "${amneziawg_go_hash}" >"${AMNEZIAWG_GO_STAMP}"
fi

echo "== Сборка awg (amneziawg-tools) =="
awg_hash="$(tree_hash "awg-v3 ENABLE_UPX=${ENABLE_UPX} HOST_ONLY=${HOST_ONLY} CARCH=${CARCH:-universal}" "${AMNEZIA_DIR}/amneziawg-tools/src" \( -name '*.[ch]' -o -name '*.S' -o -name 'Makefile' \))"
if is_current "${TAURI_RESOURCES_DIR}/awg" "${AWG_STAMP}" "${awg_hash}"; then
  echo "  awg актуален, пропускаю сборку."
else
  cd "${AMNEZIA_DIR}/amneziawg-tools/src"
  if [[ "${HOST_ONLY}" == "1" ]]; then
    echo "  [1/2] Компиляция awg для хост-архитектуры (darwin/${CARCH})..."
    rm -f "${TAURI_RESOURCES_DIR}/awg"
    make clean >/dev/null
    PLATFORM=darwin CC=clang CFLAGS="-O3 -arch ${CARCH}" LDFLAGS="-arch ${CARCH}" make wg >/dev/null
    mv wg "${TAURI_RESOURCES_DIR}/awg"
    if [[ "${ENABLE_UPX}" == "1" ]] && command -v upx >/dev/null 2>&1; then
      echo "  [2/2] Сжатие бинарника с помощью UPX..."
      upx --best --lzma --force-macos "${TAURI_RESOURCES_DIR}/awg" >/dev/null || true
    fi
    make clean >/dev/null
  else
    echo "  [1/4] Компиляция awg (darwin/arm64)..."
    rm -f "${TAURI_RESOURCES_DIR}/awg"
    make clean >/dev/null
    PLATFORM=darwin CC=clang CFLAGS="-O3 -arch arm64" LDFLAGS="-arch arm64" make wg >/dev/null
    mv wg wg-arm64

    echo "  [2/4] Компиляция awg (darwin/x86_64)..."
    make clean >/dev/null
    PLATFORM=darwin CC=clang CFLAGS="-O3 -arch x86_64" LDFLAGS="-arch x86_64" make wg >/dev/null
    mv wg wg-amd64

    echo "  [3/4] Сжатие бинарников с помощью UPX..."
    if [[ "${ENABLE_UPX}" == "1" ]] && command -v upx >/dev/null 2>&1; then
      upx --best --lzma --force-macos wg-arm64 wg-amd64 >/dev/null || true
    else
      echo "  UPX пропущен (ENABLE_UPX=1 включает сжатие)."
    fi

    echo "  [4/4] Объединение в Universal Binary..."
    lipo -create wg-arm64 wg-amd64 -output "${TAURI_RESOURCES_DIR}/awg"
    rm -f wg-arm64 wg-amd64
    make clean >/dev/null
  fi
  printf '%s\n' "${awg_hash}" >"${AWG_STAMP}"
fi

echo "== Проверка архитектур собранных ресурсов =="
file "${TAURI_RESOURCES_DIR}/amneziawg-go"
file "${TAURI_RESOURCES_DIR}/awg"
echo "Готово!"
