#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/macos-native"
BUILD_DIR="${PACKAGE_DIR}/build"
APP_NAME="VEXNativeMac"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
EXECUTABLE="${PACKAGE_DIR}/.build/release/${APP_NAME}"
ICON_SOURCE="${ROOT_DIR}/assets/vex-app-icon-source.png"
ICONSET_DIR="${BUILD_DIR}/VEXNative.iconset"
ICNS_PATH="${APP_DIR}/Contents/Resources/VEXNative.icns"
APP_VERSION="${VEX_NATIVE_VERSION:-0.1.0}"
APP_BUILD="${VEX_NATIVE_BUILD:-1}"
SPARKLE_FEED_URL="${VEX_SPARKLE_FEED_URL:-https://vexguard.app/downloads/native-macos/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${VEX_SPARKLE_PUBLIC_ED_KEY:-VEX_SPARKLE_PUBLIC_ED_KEY_NOT_SET}"
CODESIGN_IDENTITY="${VEX_CODESIGN_IDENTITY:--}"

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
  APP_VERSION="${VEX_NATIVE_VERSION:-${APP_VERSION}}"
  APP_BUILD="${VEX_NATIVE_BUILD:-${APP_BUILD}}"
  SPARKLE_FEED_URL="${VEX_SPARKLE_FEED_URL:-${SPARKLE_FEED_URL}}"
  SPARKLE_PUBLIC_ED_KEY="${VEX_SPARKLE_PUBLIC_ED_KEY:-${SPARKLE_PUBLIC_ED_KEY}}"
  CODESIGN_IDENTITY="${VEX_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY}}"
fi

if [[ ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "VEX_NATIVE_BUILD must be numeric; got '${APP_BUILD}'" >&2
  exit 1
fi

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  CODESIGN_ARGS=(--force --sign -)
else
  CODESIGN_ARGS=(--force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}")
fi

cd "${PACKAGE_DIR}"
swift build -c release

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
if ! otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
fi

SPARKLE_FRAMEWORK="$(find "${PACKAGE_DIR}/.build" -type d -path "*/release/Sparkle.framework" | head -n 1)"
if [[ -z "${SPARKLE_FRAMEWORK}" || ! -d "${SPARKLE_FRAMEWORK}" ]]; then
  SPARKLE_FRAMEWORK="$(find "${PACKAGE_DIR}/.build/artifacts" -type d -path "*/Sparkle.framework" | head -n 1)"
fi
if [[ -n "${SPARKLE_FRAMEWORK}" && -d "${SPARKLE_FRAMEWORK}" ]]; then
  ditto "${SPARKLE_FRAMEWORK}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
else
  echo "Missing Sparkle.framework. Run 'swift build -c release' in ${PACKAGE_DIR} first." >&2
  exit 1
fi

RESOURCE_BUNDLE="$(find "${PACKAGE_DIR}/.build" -type d -path "*/release/${APP_NAME}_${APP_NAME}.bundle" | head -n 1)"
if [[ -n "${RESOURCE_BUNDLE}" && -d "${RESOURCE_BUNDLE}" ]]; then
  cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/"
else
  echo "Missing SwiftPM resource bundle for ${APP_NAME}" >&2
  exit 1
fi

mkdir -p "${APP_DIR}/Contents/Resources/resources"
for resource in install-vex-vpn-helper.sh awg amneziawg-go vex-helper; do
  if [[ -f "${ROOT_DIR}/src-tauri/resources/${resource}" ]]; then
    cp "${ROOT_DIR}/src-tauri/resources/${resource}" "${APP_DIR}/Contents/Resources/resources/${resource}"
  else
    echo "Missing helper resource: ${resource}" >&2
    exit 1
  fi
done
chmod 755 "${APP_DIR}/Contents/Resources/resources/install-vex-vpn-helper.sh" \
  "${APP_DIR}/Contents/Resources/resources/awg" \
  "${APP_DIR}/Contents/Resources/resources/amneziawg-go" \
  "${APP_DIR}/Contents/Resources/resources/vex-helper"

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"

cat >"${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>app.vex.vpn.native</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VEX Native</string>
  <key>CFBundleIconFile</key>
  <string>VEXNative</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>VEX Auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>vexguard</string>
        <string>vex</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$(xml_escape "${APP_VERSION}")</string>
  <key>CFBundleVersion</key>
  <string>$(xml_escape "${APP_BUILD}")</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$(xml_escape "${SPARKLE_FEED_URL}")</string>
  <key>SUPublicEDKey</key>
  <string>$(xml_escape "${SPARKLE_PUBLIC_ED_KEY}")</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
</dict>
</plist>
PLIST

codesign "${CODESIGN_ARGS[@]}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
codesign "${CODESIGN_ARGS[@]}" --deep "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "${APP_DIR}"
