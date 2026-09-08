#!/usr/bin/env bash
set -euo pipefail

if [[ "${EAS_BUILD_PLATFORM:-}" == "android" && "${VEX_BUILD_PROFILE:-}" == "production" ]]; then
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify_android_observability.sh" env
fi

