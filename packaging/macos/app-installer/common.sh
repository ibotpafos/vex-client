#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { echo "VEX: $*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] || fail "Установка разрешена только для текущего пользователя."
[[ -n "${HOME:-}" && "${HOME}" == /* && -d "${HOME}" && ! -L "${HOME}" && -O "${HOME}" ]] || fail "Не удалось проверить домашнюю папку."
[[ "$(cd "${HOME}" && /bin/pwd -P)" == "${HOME}" ]] || fail "Домашняя папка не должна быть ссылкой."
APP_PATH="${HOME}/Applications/VEX Native.app"
[[ ! -L "${HOME}/Applications" && ! -L "${APP_PATH}" ]] || fail "Папка приложения не должна быть ссылкой."
EXPECTED_VERSION='@VERSION@'
EXPECTED_BUILD='@BUILD@'
REQUIREMENT='@REQUIREMENT@'
read_info() { /usr/libexec/PlistBuddy -c "Print :$1" "${APP_PATH}/Contents/Info.plist"; }

check_existing_version() {
  local old_version old_build
  [[ -f "${APP_PATH}/Contents/Info.plist" && ! -L "${APP_PATH}/Contents/Info.plist" ]] || fail "Некорректное существующее приложение."
  [[ "$(read_info CFBundleIdentifier)" == "app.vex.vpn.native" ]] || fail "В папке установлено другое приложение."
  old_version="$(read_info CFBundleShortVersionString)"
  old_build="$(read_info CFBundleVersion)"
  [[ "${old_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${old_build}" =~ ^[0-9]+$ ]] || fail "Не удалось сравнить версии приложения."
  /usr/bin/awk -v old="${old_version}" -v new="${EXPECTED_VERSION}" -v a="${old_build}" -v b="${EXPECTED_BUILD}" '
    BEGIN { split(old,x,"."); split(new,y,"."); for(i=1;i<=3;i++) { if(x[i]+0>y[i]+0) exit 1; if(x[i]+0<y[i]+0) exit 0; } exit (a+0>b+0) }' || fail "Уже установлена более новая версия VEX."
}
