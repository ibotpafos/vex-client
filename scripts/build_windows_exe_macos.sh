#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This helper is for macOS. Use npm run windows:release on Windows for full installers." >&2
  exit 2
fi

TARGET="${WINDOWS_TARGET:-x86_64-pc-windows-msvc}"
TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/vex-client-tauri-xwin-target}"
LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}"

if [[ -d "${LLVM_BIN}" ]]; then
  export PATH="${LLVM_BIN}:${PATH}"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    case "$1" in
      cargo-xwin) echo "Install with: cargo install cargo-xwin --locked" >&2 ;;
      llvm-lib) echo "Install with: brew install llvm" >&2 ;;
    esac
    exit 2
  fi
}

require_command npm
require_command cargo-xwin
require_command llvm-lib

echo "== VEX Windows exe cross-build on macOS =="
echo "target: ${TARGET}"
echo "target dir: ${TARGET_DIR}"

CARGO_TARGET_DIR="${TARGET_DIR}" npm run tauri:cli -- \
  build \
  --runner cargo-xwin \
  --target "${TARGET}" \
  --no-bundle \
  --ci

exe="${TARGET_DIR}/${TARGET}/release/app.exe"
if [[ ! -f "${exe}" ]]; then
  echo "Windows exe was not produced: ${exe}" >&2
  exit 1
fi

python3 - "${exe}" <<'PY'
import sys
from pathlib import Path

exe = Path(sys.argv[1])
data = exe.read_bytes()
required = b"Microsoft.Windows.Common-Controls"
if required not in data:
    raise SystemExit(f"manifest dependency missing from {exe}: {required.decode()}")
print(f"built: {exe}")
print(f"size: {exe.stat().st_size} bytes")
print("manifest: Microsoft.Windows.Common-Controls v6 present")
PY
