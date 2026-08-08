#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
parser="${root_dir}/modules/vex-vpn/ios/tunnel/WgQuickTunnelConfiguration.swift"
bootstrap="${root_dir}/scripts/bootstrap_amneziawg_ios.sh"

for key in \
  headerprotectionkey \
  contentpaddingaddition \
  rekeyaftertime \
  rekeytimeout \
  rejectaftertime \
  keepalivetimeout \
  maxhandshakeattempts; do
  rg -Fq "\"${key}\"" "${parser}"
done

rg -Fq 'interface.headerProtectionKey = headerProtectionKey' "${parser}"
rg -Fq 'interface.contentPaddingAddition = contentPaddingAdditionString' "${parser}"
rg -Fq 'interface.maxHandshakeAttempts = maxHandshakeAttemptsString' "${parser}"
rg -Fq 'peer.persistentKeepAlive = persistentKeepAliveString' "${parser}"
rg -Fq 'apple_ref="${AMNEZIAWG_APPLE_REF:-4bafa5958a80c8be76bd89d1e02984c6307769d2}"' "${bootstrap}"

swift build --package-path "${root_dir}/external/amnezia/amneziawg-apple" --target WireGuardKit
swiftc -typecheck \
  -I "${root_dir}/external/amnezia/amneziawg-apple/.build/arm64-apple-macosx/debug/Modules" \
  -Xcc -fmodule-map-file="${root_dir}/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/module.modulemap" \
  -Xcc -I -Xcc "${root_dir}/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo" \
  -Xcc -fmodule-map-file="${root_dir}/external/amnezia/amneziawg-apple/Sources/WireGuardKitC/module.modulemap" \
  -Xcc -I -Xcc "${root_dir}/external/amnezia/amneziawg-apple/Sources/WireGuardKitC" \
  -module-cache-path "${root_dir}/external/amnezia/amneziawg-apple/.build/arm64-apple-macosx/debug/ModuleCache" \
  "${parser}"
