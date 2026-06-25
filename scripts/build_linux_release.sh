#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${LINUX_TARGET:-$(rustc -vV | awk '/host:/ {print $2}')}"
ARTIFACTS_DIR="${LINUX_ARTIFACTS_DIR:-dist/linux}"
TAURI_CONFIG="${ROOT}/src-tauri/tauri.conf.json"
TAURI_CONFIG_BACKUP=""

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "${name} is required" >&2
    exit 2
  fi
}

desktop_version() {
  node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync("versions.json","utf8")).desktop.version)'
}

sha256_sidecar() {
  local path="$1"
  local name hash
  name="$(basename "$path")"
  hash="$(sha256sum "$path" | awk '{print $1}')"
  printf '%s  %s' "$hash" "$name" >"${path}.sha256"
  printf '%s\n' "$hash"
}

metadata_sig_sidecar() {
  local path="$1"
  local kind="$2"
  local hash="$3"
  local name
  name="$(basename "$path")"
  printf 'kind=%s\nname=%s\nsha256=%s\n' "$kind" "$name" "$hash" >"${path}.sig"
}

copy_asset() {
  local source="$1"
  local destination="$2"
  local kind="$3"
  local preserve_tauri_signature="${4:-0}"
  local hash

  cp -f "$source" "$destination"
  hash="$(sha256_sidecar "$destination")"

  if [[ "$preserve_tauri_signature" == "1" && -f "${source}.sig" ]]; then
    cp -f "${source}.sig" "${destination}.sig"
  else
    metadata_sig_sidecar "$destination" "$kind" "$hash"
  fi
}

latest_file() {
  local pattern="$1"
  find "${ROOT}/src-tauri/target" -path "$pattern" -type f -printf '%T@ %p\n' |
    sort -rn |
    awk 'NR == 1 {$1=""; sub(/^ /, ""); print}'
}

prepare_tauri_sidecar_stub() {
  local helper_dir helper_src helper_bin
  helper_dir="${ROOT}/src-tauri/target/${TARGET}/release"
  helper_src="$(mktemp --suffix=.rs)"
  helper_bin="${helper_dir}/helper"

  mkdir -p "${helper_dir}"
  printf 'fn main() {}\n' >"${helper_src}"
  rustc --target "${TARGET}" -C opt-level=z -C strip=symbols "${helper_src}" -o "${helper_bin}"
  rm -f "${helper_src}"
}

restore_tauri_config() {
  if [[ -n "${TAURI_CONFIG_BACKUP}" && -f "${TAURI_CONFIG_BACKUP}" ]]; then
    mv "${TAURI_CONFIG_BACKUP}" "${TAURI_CONFIG}"
  fi
}

configure_tauri() {
  local version="$1"
  TAURI_CONFIG_BACKUP="$(mktemp)"
  cp "${TAURI_CONFIG}" "${TAURI_CONFIG_BACKUP}"
  node - "${TAURI_CONFIG}" "${version}" "${TAURI_SIGNING_PUBLIC_KEY}" <<'NODE'
const fs = require("fs");
const [configPath, version, pubkey] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));

config.productName = "VEX";
config.version = version;
config.mainBinaryName = "app";
config.plugins = config.plugins || {};
config.plugins.updater = config.plugins.updater || {};
config.plugins.updater.pubkey = pubkey;
config.bundle = config.bundle || {};
config.bundle.active = true;
config.bundle.createUpdaterArtifacts = "v1Compatible";
config.bundle.targets = ["appimage", "deb"];
config.bundle.resources = [];

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

install_deb_helper_payload() {
  local deb="$1"
  local helper="${ROOT}/packaging/linux/vex-vpn-linux-helper"
  local workdir control_dir existing_postinst original_postinst

  [[ -r "$helper" ]] || return 0

  workdir="$(mktemp -d)"
  control_dir="${workdir}/DEBIAN"
  existing_postinst="${control_dir}/postinst"
  original_postinst="${control_dir}/postinst.original"

  dpkg-deb -R "$deb" "$workdir"
  install -d -m 0755 "${workdir}/usr/local/libexec" "${workdir}/etc/sudoers.d"
  install -m 0755 "$helper" "${workdir}/usr/local/libexec/vex-vpn-linux-helper"
  cat >"${workdir}/etc/sudoers.d/vex-vpn-linux-helper" <<'EOF'
%sudo ALL=(root) NOPASSWD: /usr/local/libexec/vex-vpn-linux-helper
%wheel ALL=(root) NOPASSWD: /usr/local/libexec/vex-vpn-linux-helper
EOF
  chmod 0440 "${workdir}/etc/sudoers.d/vex-vpn-linux-helper"

  if [[ -f "$existing_postinst" ]]; then
    cp "$existing_postinst" "$original_postinst"
  fi
  cat >"$existing_postinst" <<'EOF'
#!/usr/bin/env sh
set -e

if command -v visudo >/dev/null 2>&1; then
  visudo -cf /etc/sudoers.d/vex-vpn-linux-helper >/dev/null
fi
EOF
  if [[ -f "$original_postinst" ]]; then
    tail -n +2 "$original_postinst" >>"$existing_postinst"
  else
    printf '\nexit 0\n' >>"$existing_postinst"
  fi
  chmod 0755 "$existing_postinst"

  dpkg-deb -b "$workdir" "$deb"
  rm -rf "$workdir"
}

require_env TAURI_SIGNING_PRIVATE_KEY
require_env TAURI_SIGNING_PRIVATE_KEY_PASSWORD
require_env TAURI_SIGNING_PUBLIC_KEY

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Linux release build must run on Linux." >&2
  exit 2
fi

trap restore_tauri_config EXIT

VERSION="${VERSION:-$(desktop_version)}"
export TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

configure_tauri "$VERSION"

echo "== VEX Linux Tauri release =="
echo "version: ${VERSION}"
echo "target: ${TARGET}"

prepare_tauri_sidecar_stub
npm run tauri:cli -- build --target "${TARGET}"

appimage="$(latest_file "*/release/bundle/appimage/*.AppImage")"
deb="$(latest_file "*/release/bundle/deb/*.deb")"

if [[ -z "${appimage}" || ! -r "${appimage}" ]]; then
  echo "AppImage was not produced" >&2
  exit 1
fi
if [[ ! -r "${appimage}.sig" ]]; then
  echo "Tauri updater signature was not produced for AppImage: ${appimage}.sig" >&2
  exit 1
fi
if [[ -z "${deb}" || ! -r "${deb}" ]]; then
  echo "Debian package was not produced" >&2
  exit 1
fi

install_deb_helper_payload "${deb}"

mkdir -p "${ROOT}/${ARTIFACTS_DIR}"

appimage_name="Vex-Linux-${VERSION}.AppImage"
deb_name="Vex-Linux-${VERSION}.deb"
appimage_dest="${ROOT}/${ARTIFACTS_DIR}/${appimage_name}"
deb_dest="${ROOT}/${ARTIFACTS_DIR}/${deb_name}"

copy_asset "${appimage}" "${appimage_dest}" "appimage" 1
copy_asset "${deb}" "${deb_dest}" "deb" 1

node - "${ROOT}/${ARTIFACTS_DIR}/release-manifest.json" "${VERSION}" "${TARGET}" "${appimage_name}" "${deb_name}" <<'NODE'
const fs = require("fs");
const [manifestPath, version, target, appimageName, debName] = process.argv.slice(2);
const manifest = {
  version,
  target,
  updater: appimageName,
  updaterSignature: `${appimageName}.sig`,
  assets: [
    appimageName,
    `${appimageName}.sha256`,
    `${appimageName}.sig`,
    debName,
    `${debName}.sha256`,
    `${debName}.sig`,
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

echo "Linux release assets:"
find "${ROOT}/${ARTIFACTS_DIR}" -maxdepth 1 -type f -print | sort | sed 's/^/  /'
