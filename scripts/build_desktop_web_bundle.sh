#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mobile_dir="${root_dir}"
out_dir="${DESKTOP_WEB_BUNDLE_OUT_DIR:-${root_dir}/dist/downloads}"
if [[ "${out_dir}" != /* ]]; then
  out_dir="$(pwd)/${out_dir}"
fi
channel="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-${EXPO_PUBLIC_VEX_RELEASE_CHANNEL:-production}}"
version="$(python3 "${root_dir}/scripts/release_download_names.py" version desktop-web)"
bundle_name="$(python3 "${root_dir}/scripts/release_download_names.py" name desktop-web bundle --version "${version}")"
bundle_path="${out_dir}/${bundle_name}"
export_dir="${mobile_dir}/dist"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

require npm
require python3
require zip

mkdir -p "${out_dir}"
rm -f "${bundle_path}" "${bundle_path}.sha256" "${bundle_path}.sig"

if [[ "${DESKTOP_WEB_SKIP_BUILD:-0}" != "1" ]]; then
  (
    cd "${mobile_dir}"
    NODE_ENV="${NODE_ENV:-production}" \
    EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${channel}" \
    EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${channel}" \
    npm run build:web
  )
fi

if [[ ! -d "${export_dir}" ]]; then
  echo "desktop web export not found: ${export_dir}" >&2
  exit 1
fi

(
  cd "${export_dir}"
  zip -qry "${bundle_path}" .
)
"${root_dir}/scripts/generate_release_metadata.sh" "${bundle_path}"

echo "Desktop web bundle written to ${bundle_path}"
