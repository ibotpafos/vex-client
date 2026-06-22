#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts_dir="${ANDROID_ARTIFACTS_DIR:-dist/android}"
release_abis="${ANDROID_RELEASE_ABIS:-arm64-v8a,armeabi-v7a}"
variant="${ANDROID_RELEASE_VARIANT:-release}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "${name} is required" >&2
    exit 2
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  echo "missing required command: sha256sum or shasum" >&2
  exit 2
}

write_sidecars() {
  local path="$1"
  local kind="$2"
  local name hash
  name="$(basename "$path")"
  hash="$(sha256_file "$path")"
  printf '%s  %s' "$hash" "$name" >"${path}.sha256"

  if [[ "$kind" == "apk" ]] && command -v apksigner >/dev/null 2>&1; then
    if apksigner verify --print-certs "$path" >"${path}.sig" 2>/dev/null; then
      return
    fi
  fi

  printf 'kind=%s\nname=%s\nsha256=%s\n' "$kind" "$name" "$hash" >"${path}.sig"
}

release_version() {
  node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync("versions.json","utf8")).android.version)'
}

release_build() {
  node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync("versions.json","utf8")).android.build)'
}

cd "${root_dir}"

require_env VEX_UPLOAD_STORE_FILE
require_env VEX_UPLOAD_STORE_PASSWORD
require_env VEX_UPLOAD_KEY_ALIAS
require_env VEX_UPLOAD_KEY_PASSWORD

"${root_dir}/scripts/bootstrap_amneziawg_android.sh"

export AMNEZIAWG_TUNNEL_DIR="${AMNEZIAWG_TUNNEL_DIR:-"${root_dir}/external/amnezia/amneziawg-android/tunnel"}"
export ANDROID_HOME="${ANDROID_HOME:-"${HOME}/Library/Android/sdk"}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-"${ANDROID_HOME}"}"
export NODE_ENV="${NODE_ENV:-production}"
export VEX_BUILD_PROFILE="${VEX_BUILD_PROFILE:-production}"
export EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${EXPO_PUBLIC_VEX_RELEASE_CHANNEL:-production}"
export EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-production}"
export VEX_UPDATES_ENABLED="${VEX_UPDATES_ENABLED:-1}"
export VEX_OTA_PROVIDER="${VEX_OTA_PROVIDER:-expo-open-ota}"
export VEX_RUNTIME_VERSION="${VEX_RUNTIME_VERSION:-$(node -p "require('./app.json').expo.version")}"
export VEX_EAS_PROJECT_ID="${VEX_EAS_PROJECT_ID:-$(node -p "require('./app.json').expo.extra.eas.projectId")}"
export ORG_GRADLE_PROJECT_reactNativeArchitectures="${ORG_GRADLE_PROJECT_reactNativeArchitectures:-${release_abis}}"
export VEX_ANDROID_FAST_ABI="${VEX_ANDROID_FAST_ABI:-${release_abis}}"

case "$variant" in
  release)
    gradle_task=":app:assembleRelease"
    output_apk="${root_dir}/android/app/build/outputs/apk/release/app-release.apk"
    ;;
  local)
    gradle_task=":app:assembleLocal"
    output_apk="${root_dir}/android/app/build/outputs/apk/local/app-local.apk"
    ;;
  *)
    echo "unsupported ANDROID_RELEASE_VARIANT=${variant}; expected release or local" >&2
    exit 2
    ;;
esac

echo "== VEX Android release =="
echo "version: $(release_version)"
echo "build: $(release_build)"
echo "variant: ${variant}"
echo "abis: ${ORG_GRADLE_PROJECT_reactNativeArchitectures}"

cd "${root_dir}/android"
./gradlew "${gradle_task}" \
  -PreactNativeArchitectures="${ORG_GRADLE_PROJECT_reactNativeArchitectures}" \
  -PVEX_ANDROID_FAST_ABI="${VEX_ANDROID_FAST_ABI}" \
  "$@"

cd "${root_dir}"

if [[ ! -f "$output_apk" ]]; then
  echo "APK was not produced: ${output_apk}" >&2
  exit 1
fi

mkdir -p "${root_dir}/${artifacts_dir}"

version="$(release_version)"
build="$(release_build)"
apk_name="Vex-Android-${version}-${build}.apk"
apk_dest="${root_dir}/${artifacts_dir}/${apk_name}"

cp -f "$output_apk" "$apk_dest"
write_sidecars "$apk_dest" "apk"

node - "${root_dir}/${artifacts_dir}/release-manifest.json" "${version}" "${build}" "${variant}" "${apk_name}" <<'NODE'
const fs = require("fs");
const [manifestPath, version, build, variant, apkName] = process.argv.slice(2);
const manifest = {
  version,
  build: Number(build),
  variant,
  updater: apkName,
  updaterSignature: `${apkName}.sig`,
  assets: [
    apkName,
    `${apkName}.sha256`,
    `${apkName}.sig`,
  ],
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

while IFS= read -r asset; do
  path="${root_dir}/${artifacts_dir}/${asset}"
  if [[ ! -f "$path" ]]; then
    echo "release asset missing: $path" >&2
    exit 1
  fi
done < <(node -e 'const fs=require("fs"); for (const a of JSON.parse(fs.readFileSync(process.argv[1],"utf8")).assets) console.log(a)' "${root_dir}/${artifacts_dir}/release-manifest.json")

echo "Android release assets:"
find "${root_dir}/${artifacts_dir}" -maxdepth 1 -type f -print | sort | sed 's/^/  /'
