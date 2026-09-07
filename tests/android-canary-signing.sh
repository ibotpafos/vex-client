#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for build in "" nope 0 1005660 1005661 1005664; do
  out=$(bash scripts/sign_android_canary_candidate_ci.sh fixture fixture "$build" 2>&1) && { echo INVALID_BUILD_ACCEPTED; exit 1; }
  grep -q '^Unsupported candidate build$' <<< "$out" || { echo WRONG_REJECTION_PATH; exit 1; }
done
echo INVALID_BUILD_REJECTED_BEFORE_SECRET_ACCESS=PASS
