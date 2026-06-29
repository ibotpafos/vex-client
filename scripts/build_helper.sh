#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/scripts/local_release_cache_bootstrap.sh"

TAURI_DIR="${ROOT_DIR}/src-tauri"

cd "${TAURI_DIR}"
mkdir -p resources
touch resources/vex-helper

OS="$(uname -s 2>/dev/null || echo "Unknown")"
STAMP_DIR="${TAURI_DIR}/target/.vex-stamps"
HELPER_STAMP="${STAMP_DIR}/vex-helper.sha256"
ENABLE_UPX="${ENABLE_UPX:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
HELPER_TARGET="${HELPER_TARGET:-universal}"

host_rust_target() {
  case "$(uname -m)" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "" ;;
  esac
}

source_hash() {
  {
    printf '%s\n' "build-helper-v4"
    printf '%s\n' "ENABLE_UPX=${ENABLE_UPX}"
    printf '%s\n' "HELPER_TARGET=${HELPER_TARGET}"
    find src -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) -print 2>/dev/null
    printf '%s\n' Cargo.toml Cargo.lock
  } | LC_ALL=C sort -u | while IFS= read -r path; do
    if [[ -f "${path}" ]]; then
      shasum -a 256 "${path}"
    else
      printf '%s\n' "${path}"
    fi
  done | shasum -a 256 | awk '{print $1}'
  return 0
}

ensure_helper_bundle_alias() {
  local rust_target="$1"
  [[ -n "${rust_target}" ]] || return 0

  local profile profile_dir source_bin alias_bin
  for profile in release debug; do
    profile_dir="target/${rust_target}/${profile}"
    source_bin="${profile_dir}/vex-helper"
    alias_bin="${profile_dir}/helper"
    mkdir -p "${profile_dir}"

    if [[ -x "${source_bin}" ]]; then
      cp "${source_bin}" "${alias_bin}"
    elif [[ -x resources/vex-helper ]]; then
      cp resources/vex-helper "${alias_bin}"
    fi
    [[ ! -f "${alias_bin}" ]] || chmod 755 "${alias_bin}"
    sign_macos_binary "${alias_bin}"
  done
}

sign_macos_binary() {
  local binary="$1"
  if [[ "${OS}" != "Darwin" || ! -x "${binary}" ]]; then
    return 0
  fi
  codesign --force --sign - "${binary}" >/dev/null
  codesign --verify --strict --verbose=2 "${binary}" >/dev/null
}

helper_is_current() {
  [[ "${FORCE_REBUILD}" == "1" ]] && return 1
  [[ -x resources/vex-helper && -f "${HELPER_STAMP}" ]] || return 1
  [[ "$(cat "${HELPER_STAMP}")" == "$(source_hash)" ]]
}

write_stamp() {
  mkdir -p "${STAMP_DIR}"
  source_hash >"${HELPER_STAMP}"
}

if [[ "${OS}" == "Darwin" && "${HELPER_TARGET}" == "host" ]]; then
  rust_target="$(host_rust_target)"
  if [[ -z "${rust_target}" ]]; then
    echo "Не удалось определить локальную архитектуру для vex-helper" >&2
    exit 1
  fi

  if helper_is_current; then
    echo "== vex-helper актуален, пропускаю сборку =="
    ensure_helper_bundle_alias "${rust_target}"
    file resources/vex-helper
    exit 0
  fi

  echo "== Сборка локального vex-helper (${rust_target}) =="
  cargo build --release --features macos-helper --bin vex-helper --target "${rust_target}"
  ensure_helper_bundle_alias "${rust_target}"
  cp "target/${rust_target}/release/vex-helper" resources/vex-helper
  sign_macos_binary resources/vex-helper
  write_stamp

  echo "== Проверка архитектуры vex-helper =="
  file resources/vex-helper
elif [[ "${OS}" == "Darwin" ]]; then
  if helper_is_current; then
    echo "== vex-helper актуален, пропускаю сборку =="
    ensure_helper_bundle_alias aarch64-apple-darwin
    ensure_helper_bundle_alias x86_64-apple-darwin
    ensure_helper_bundle_alias universal-apple-darwin
    file resources/vex-helper
    exit 0
  fi

  echo "== Сборка универсального vex-helper (macOS) =="
  
  echo "  [1/4] Компиляция vex-helper (aarch64 + x86_64)..."
  cargo build --release --features macos-helper --bin vex-helper --target aarch64-apple-darwin &
  pid_arm="$!"
  cargo build --release --features macos-helper --bin vex-helper --target x86_64-apple-darwin &
  pid_x64="$!"
  wait "${pid_arm}"
  wait "${pid_x64}"
  
  echo "  [3/4] Сжатие бинарников с помощью UPX..."
  if [[ "${ENABLE_UPX}" == "1" ]] && command -v upx >/dev/null 2>&1; then
    upx --best --lzma --force-macos target/aarch64-apple-darwin/release/vex-helper target/x86_64-apple-darwin/release/vex-helper >/dev/null || true
  else
    echo "  UPX пропущен (ENABLE_UPX=1 включает сжатие)."
  fi

  echo "  [4/4] Объединение в Universal Binary через lipo..."
  lipo -create \
    target/aarch64-apple-darwin/release/vex-helper \
    target/x86_64-apple-darwin/release/vex-helper \
    -output resources/vex-helper
  sign_macos_binary resources/vex-helper
    
  mkdir -p target/universal-apple-darwin/release
  cp resources/vex-helper target/universal-apple-darwin/release/vex-helper
  ensure_helper_bundle_alias aarch64-apple-darwin
  ensure_helper_bundle_alias x86_64-apple-darwin
  ensure_helper_bundle_alias universal-apple-darwin
  write_stamp
    
  echo "== Проверка архитектуры vex-helper =="
  file resources/vex-helper
else
  if helper_is_current; then
    echo "== vex-helper актуален, пропускаю сборку =="
    exit 0
  fi

  echo "vex-helper is macOS-only; skipping helper build on ${OS}." >&2
  exit 2
fi

echo "Сборка хелпера завершена!"
