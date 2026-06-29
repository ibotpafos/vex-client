#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT}/scripts/local_release_cache_bootstrap.sh"
cd "${ROOT}"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

exec "$@"
