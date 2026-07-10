#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
operation="${1:-publish}"
branch="${2:-production}"
platform="${OTA_PLATFORM:-}"

case "${operation}" in
  publish|republish|rollback) ;;
  *) printf 'unsupported OTA operation: %s\n' "${operation}" >&2; exit 2 ;;
esac
case "${branch}" in
  preview|production) ;;
  *) printf 'unsupported OTA branch: %s\n' "${branch}" >&2; exit 2 ;;
esac
case "${platform}" in
  android|ios) ;;
  *)
    printf 'OTA_PLATFORM must be exactly android or ios; cross-platform publishing is intentionally disabled.\n' >&2
    exit 2
    ;;
esac

cd "${root_dir}"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  printf 'tracked files are dirty; commit and verify the exact OTA source before publishing.\n' >&2
  exit 2
fi

if [[ "${operation}" == "publish" || "${operation}" == "republish" || "${operation}" == "rollback" ]]; then
  runtime_version="${VEX_RUNTIME_VERSION:-}"
  if [[ -z "${runtime_version}" ]]; then
    printf 'VEX_RUNTIME_VERSION is required for every OTA operation.\n' >&2
    exit 2
  fi
  current_runtime="$(node -e "const v=require('./versions.json'); process.stdout.write(String(v['${platform}'].version))")"
  if [[ "${runtime_version}" != "${current_runtime}" ]]; then
    if [[ "${operation}" == "publish" ]]; then
      printf 'refusing to build a new %s OTA from source version %s for older runtime %s; check out source matching that runtime or republish a verified update.\n' \
        "${platform}" "${current_runtime}" "${runtime_version}" >&2
      exit 2
    fi
    if [[ "${OTA_ALLOW_NONCURRENT_RUNTIME:-0}" != "1" ]]; then
      printf 'runtime %s differs from current %s runtime %s; set OTA_ALLOW_NONCURRENT_RUNTIME=1 only for an intentional republish or rollback.\n' \
        "${runtime_version}" "${platform}" "${current_runtime}" >&2
      exit 2
    fi
  fi
fi

profile="${branch}"
args=("${operation}" --branch "${branch}" --platform "${platform}")
if [[ "${operation}" == "publish" ]]; then
  args+=(--nonInteractive)
  if [[ -n "${OTA_MESSAGE:-}" ]]; then
    args+=(--message "${OTA_MESSAGE}")
  fi
fi

printf 'OTA operation=%s branch=%s platform=%s runtime=%s\n' \
  "${operation}" "${branch}" "${platform}" "${VEX_RUNTIME_VERSION:-server-selected}"
exec bash scripts/run_with_local_release_cache.sh env \
  NODE_ENV=production \
  VEX_BUILD_PROFILE="${profile}" \
  VEX_UPDATES_ENABLED=1 \
  VEX_OTA_PROVIDER=expo-open-ota \
  EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${branch}" \
  EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${branch}" \
  RELEASE_CHANNEL="${branch}" \
  eoas "${args[@]}"
