#!/usr/bin/env bash

if [[ -n "${VEX_LOCAL_RELEASE_CACHE_BOOTSTRAPPED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_vex_cache_script_path="${BASH_SOURCE[0]:-$0}"
_vex_cache_root="$(cd "$(dirname "${_vex_cache_script_path}")/.." && pwd)"

# This file is intended to be sourced by build entrypoints so cache env vars
# remain active for Gradle, Cargo, Go, Expo, Metro and temporary build files.
source "${_vex_cache_root}/scripts/local_release_env.sh"

export VEX_LOCAL_CACHE_MOVE_EXISTING="${VEX_LOCAL_CACHE_MOVE_EXISTING:-1}"
bash "${_vex_cache_root}/scripts/setup_local_release_cache.sh" >/dev/null

export VEX_LOCAL_RELEASE_CACHE_BOOTSTRAPPED=1
