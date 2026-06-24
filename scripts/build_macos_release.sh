#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${MACOS_ARTIFACTS_DIR:-dist/macos}"
TAURI_CONFIG="${ROOT}/src-tauri/tauri.conf.json"
TARGET="${MACOS_TARGET:-universal-apple-darwin}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "${name} is required" >&2
    exit 2
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

desktop_version() {
  node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync("src-tauri/tauri.conf.json","utf8")).version)'
}

configured_pubkey() {
  node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync("src-tauri/tauri.conf.json","utf8")).plugins.updater.pubkey)'
}

latest_file() {
  local pattern="$1"
  python3 - "${ROOT}/src-tauri/target" "${pattern}" <<'PY'
import glob
import os
import sys

root, pattern = sys.argv[1:]
matches = glob.glob(os.path.join(root, pattern), recursive=True)
files = [path for path in matches if os.path.isfile(path)]
if files:
    print(max(files, key=os.path.getmtime))
PY
}

sha256_sidecar() {
  local path="$1"
  local name hash
  name="$(basename "$path")"
  hash="$(shasum -a 256 "$path" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$name" >"${path}.sha256"
}

copy_asset() {
  local source="$1"
  local destination="$2"
  cp -f "$source" "$destination"
  sha256_sidecar "$destination"
}

require_env TAURI_SIGNING_PRIVATE_KEY
require_env TAURI_SIGNING_PRIVATE_KEY_PASSWORD
require_env TAURI_SIGNING_PUBLIC_KEY
require_command node
require_command npm
require_command python3
require_command shasum
require_command ditto
require_command codesign

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS release build must run on macOS." >&2
  exit 2
fi

cd "${ROOT}"

VERSION="${MACOS_RELEASE_VERSION:-$(desktop_version)}"
CONFIGURED_PUBKEY="$(configured_pubkey)"
if [[ "${TAURI_SIGNING_PUBLIC_KEY}" != "${CONFIGURED_PUBKEY}" ]]; then
  echo "TAURI_SIGNING_PUBLIC_KEY does not match src-tauri/tauri.conf.json updater pubkey" >&2
  exit 1
fi

export TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

echo "== VEX macOS Tauri release =="
echo "version: ${VERSION}"
echo "target: ${TARGET}"

npm run build:native:macos
npm run tauri:cli -- build --target "${TARGET}" --config "$(node - "${VERSION}" <<'NODE'
const [version] = process.argv.slice(2);
const config = {
  productName: "VEX",
  version,
  bundle: {
    active: true,
    createUpdaterArtifacts: "v1Compatible",
    targets: ["app", "dmg"],
    resources: [
      "resources/amneziawg-go",
      "resources/awg",
      "resources/vex-helper",
      "resources/install-vex-vpn-helper.sh",
    ],
    macOS: {
      signingIdentity: "-",
    },
  },
};
process.stdout.write(JSON.stringify(config));
NODE
)"

bundle_dir="${ROOT}/src-tauri/target/${TARGET}/release/bundle"
dmg="$(latest_file "${TARGET}/release/bundle/dmg/*.dmg")"
updater="$(latest_file "${TARGET}/release/bundle/macos/*.app.tar.gz")"
app="${bundle_dir}/macos/VEX.app"

if [[ -z "${dmg}" || ! -r "${dmg}" ]]; then
  echo "DMG was not produced" >&2
  exit 1
fi
if [[ -z "${updater}" || ! -r "${updater}" ]]; then
  echo "Tauri updater tarball was not produced" >&2
  exit 1
fi
if [[ ! -s "${updater}.sig" ]]; then
  echo "Tauri updater signature was not produced: ${updater}.sig" >&2
  exit 1
fi
if [[ ! -d "${app}" ]]; then
  echo "App bundle was not produced: ${app}" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=4 "${app}"

for resource in amneziawg-go awg vex-helper install-vex-vpn-helper.sh; do
  if [[ ! -e "${app}/Contents/Resources/${resource}" && ! -e "${app}/Contents/Resources/resources/${resource}" ]]; then
    echo "app resource missing: ${resource}" >&2
    exit 1
  fi
done

mkdir -p "${ROOT}/${ARTIFACTS_DIR}"

dmg_name="Vex-macOS-${VERSION}.dmg"
updater_name="Vex-macOS-${VERSION}.app.tar.gz"
zip_name="Vex-macOS-${VERSION}.zip"

dmg_dest="${ROOT}/${ARTIFACTS_DIR}/${dmg_name}"
updater_dest="${ROOT}/${ARTIFACTS_DIR}/${updater_name}"
zip_dest="${ROOT}/${ARTIFACTS_DIR}/${zip_name}"

copy_asset "${dmg}" "${dmg_dest}"
copy_asset "${updater}" "${updater_dest}"
cp -f "${updater}.sig" "${updater_dest}.sig"
ditto -c -k --rsrc --sequesterRsrc --keepParent "${app}" "${zip_dest}"
sha256_sidecar "${zip_dest}"

node - "${ROOT}/${ARTIFACTS_DIR}/release-manifest.json" "${VERSION}" "${TARGET}" "${dmg_name}" "${updater_name}" "${zip_name}" <<'NODE'
const fs = require("fs");
const [manifestPath, version, target, dmgName, updaterName, zipName] = process.argv.slice(2);
const manifest = {
  version,
  target,
  updater: updaterName,
  updaterSignature: `${updaterName}.sig`,
  assets: [
    dmgName,
    `${dmgName}.sha256`,
    updaterName,
    `${updaterName}.sha256`,
    `${updaterName}.sig`,
    zipName,
    `${zipName}.sha256`,
  ],
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

while IFS= read -r asset; do
  path="${ROOT}/${ARTIFACTS_DIR}/${asset}"
  if [[ ! -f "$path" ]]; then
    echo "release asset missing: $path" >&2
    exit 1
  fi
done < <(node -e 'const fs=require("fs"); for (const a of JSON.parse(fs.readFileSync(process.argv[1],"utf8")).assets) console.log(a)' "${ROOT}/${ARTIFACTS_DIR}/release-manifest.json")

echo "macOS release assets:"
find "${ROOT}/${ARTIFACTS_DIR}" -maxdepth 1 -type f -print | sort | sed 's/^/  /'
