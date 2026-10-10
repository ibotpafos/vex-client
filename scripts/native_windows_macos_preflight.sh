#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This compatibility entrypoint is for macOS; use scripts/native_windows_preflight.sh on Linux." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
bash scripts/native_windows_preflight.sh
npm run check
echo "Native Windows macOS preflight passed."
