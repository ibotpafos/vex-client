#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <artifact-path> [artifact-path...]" >&2
  exit 2
fi

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

require awk
require basename

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return
  fi

  local sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "${sdk_dir}" && -d "${HOME:-}/Library/Android/sdk" ]]; then
    sdk_dir="${HOME}/Library/Android/sdk"
  fi
  if [[ -z "${sdk_dir}" || ! -d "${sdk_dir}/build-tools" ]]; then
    return
  fi

  find "${sdk_dir}/build-tools" -maxdepth 2 -type f -name apksigner | sort -V | tail -n 1
}

write_default_signature_sidecar() {
  local artifact_name="$1"
  local artifact_path="$2"
  local sha256="$3"
  printf 'apk=%s\nsha256=%s\n' "${artifact_name}" "${sha256}" > "${artifact_path}.sig"
}

write_apk_signature_sidecar() {
  local artifact_name="$1"
  local artifact_path="$2"
  local sha256="$3"
  local tmp
  tmp="$(mktemp)"
  local apksigner_bin
  apksigner_bin="$(find_apksigner || true)"

  if [[ -n "${apksigner_bin}" ]]; then
    if "${apksigner_bin}" verify --print-certs "${artifact_path}" >"${tmp}" 2>/dev/null && grep -qi 'Signer #1\|Signer #1 certificate\|V[0-9] Signer' "${tmp}"; then
      mv "${tmp}" "${artifact_path}.sig"
      return
    fi
  fi

  rm -f "${tmp}"
  write_default_signature_sidecar "${artifact_name}" "${artifact_path}" "${sha256}"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  echo "missing required command: shasum or sha256sum" >&2
  exit 2
}

for artifact_path in "$@"; do
  [[ -f "${artifact_path}" ]] || {
    echo "artifact not found: ${artifact_path}" >&2
    exit 1
  }

  artifact_name="$(basename "${artifact_path}")"
  sha256="$(sha256_file "${artifact_path}")"
  printf '%s  %s\n' "${sha256}" "${artifact_name}" > "${artifact_path}.sha256"

  case "${artifact_name}" in
    *.apk)
      write_apk_signature_sidecar "${artifact_name}" "${artifact_path}" "${sha256}"
      ;;
    *.zip)
      if command -v osslsigncode >/dev/null 2>&1; then
        exe_candidate="$(mktemp -d "${TMPDIR:-/tmp}/vex-release-metadata.XXXXXX")"
        trap 'rm -rf "${exe_candidate}"' EXIT
        if unzip -qq -j "${artifact_path}" '*/VEX.exe' -d "${exe_candidate}" 2>/dev/null && [[ -f "${exe_candidate}/VEX.exe" ]]; then
          osslsigncode verify -in "${exe_candidate}/VEX.exe" > "${artifact_path}.sig" 2>/dev/null || printf 'archive=%s\nsha256=%s\n' "${artifact_name}" "${sha256}" > "${artifact_path}.sig"
        else
          printf 'archive=%s\nsha256=%s\n' "${artifact_name}" "${sha256}" > "${artifact_path}.sig"
        fi
        rm -rf "${exe_candidate}"
        trap - EXIT
      else
        printf 'archive=%s\nsha256=%s\n' "${artifact_name}" "${sha256}" > "${artifact_path}.sig"
      fi
      ;;
    *)
      printf 'artifact=%s\nsha256=%s\n' "${artifact_name}" "${sha256}" > "${artifact_path}.sig"
      ;;
  esac

  echo "${artifact_name}: generated ${artifact_name}.sha256 and ${artifact_name}.sig"
done
