#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR"
IOS_DIR="$APP_DIR/ios"

fail() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

command -v xcodebuild >/dev/null || fail "xcodebuild is not installed or not in PATH"
command -v xcrun >/dev/null || fail "xcrun is not installed or not in PATH"

[ -d "$IOS_DIR/VEX.xcworkspace" ] || fail "ios/VEX.xcworkspace is missing; run: npx expo prebuild --platform ios"
[ -f "$IOS_DIR/Podfile.lock" ] || fail "ios/Podfile.lock is missing; run: cd ios && pod install"
[ -f "$APP_DIR/modules/vex-vpn/ios/tunnel/PacketTunnelProvider.swift" ] || fail "PacketTunnelProvider.swift is missing"
[ -f "$APP_DIR/modules/vex-vpn/ios/tunnel/VexVpnTunnel.entitlements" ] || fail "VexVpnTunnel.entitlements is missing"

echo "== Xcode SDKs =="
xcodebuild -showsdks | sed -n '/iOS SDKs:/,/macOS SDKs:/p'

echo "== Simulator runtimes =="
runtimes="$(xcrun simctl list runtimes)"
echo "$runtimes"
if ! printf '%s\n' "$runtimes" | grep -q 'iOS .* - com.apple.CoreSimulator.SimRuntime.iOS'; then
  warn "No iOS Simulator runtime is installed. Install it in Xcode > Settings > Components before simulator builds."
fi

echo "== Entitlements =="
/usr/libexec/PlistBuddy -c "Print :com.apple.developer.networking.networkextension" "$IOS_DIR/VEX/VEX.entitlements" >/dev/null \
  || fail "Network Extension entitlement is missing in ios/VEX/VEX.entitlements"
/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$IOS_DIR/VEX/VEX.entitlements" >/dev/null \
  || fail "App Group entitlement is missing in ios/VEX/VEX.entitlements"
/usr/libexec/PlistBuddy -c "Print :NSSupportsLiveActivities" "$IOS_DIR/VEX/Info.plist" >/dev/null \
  || fail "NSSupportsLiveActivities is missing in ios/VEX/Info.plist"

/usr/libexec/PlistBuddy -c "Print :com.apple.developer.networking.networkextension" "$APP_DIR/modules/vex-vpn/ios/tunnel/VexVpnTunnel.entitlements" >/dev/null \
  || fail "Network Extension entitlement is missing in VexVpnTunnel.entitlements"
/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$APP_DIR/modules/vex-vpn/ios/tunnel/VexVpnTunnel.entitlements" >/dev/null \
  || fail "App Group entitlement is missing in VexVpnTunnel.entitlements"

echo "== Xcode VPN extension target =="
ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/VEX.xcodeproj')
target = project.targets.find { |item| item.name == 'VexVpnTunnel' }
abort('error: VexVpnTunnel target is missing; run: npm run ios:sync-vpn-extension') unless target
abort('error: VexVpnTunnel has no PacketTunnelProvider.swift source') unless target.source_build_phase.files_references.any? { |file| file.path == 'PacketTunnelProvider.swift' }
abort('error: VexVpnTunnel has no WgQuickTunnelConfiguration.swift source') unless target.source_build_phase.files_references.any? { |file| file.path == 'WgQuickTunnelConfiguration.swift' }
stale_sources = ['String+ArrayConversion.swift', 'TunnelConfiguration+WgQuickConfig.swift']
stale_sources.each do |source|
  abort("error: stale Amnezia shared model source is still attached to VexVpnTunnel: #{source}") if target.source_build_phase.files_references.any? { |file| file.path == source }
end
abort('error: VexVpnTunnel has no WireGuardKit package product dependency') unless target.package_product_dependencies.any? { |dependency| dependency.product_name == 'WireGuardKit' }
abort('error: VexVpnTunnel does not link WireGuardKit') unless target.frameworks_build_phase.files.any? { |file| file.display_name == 'WireGuardKit' }
abort('error: VexVpnTunnel has no AmneziaWG bridge build phase') unless target.shell_script_build_phases.any? { |phase| phase.name == 'Build AmneziaWG bridge' }
app = project.targets.find { |item| item.name == 'VEX' }
abort('error: VEX target is missing') unless app
embed = app.copy_files_build_phases.find { |phase| phase.display_name == 'Embed App Extensions' }
abort('error: Embed App Extensions phase is missing') unless embed
abort('error: VexVpnTunnel.appex is not embedded into VEX') unless embed.files_references.any? { |file| file&.display_name == 'VexVpnTunnel.appex' }
puts 'VexVpnTunnel target is wired'
RUBY

echo "== Xcode Live Activity extension target =="
ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/VEX.xcodeproj')
target = project.targets.find { |item| item.name == 'VexLiveActivityWidgetExtension' }
abort('error: VexLiveActivityWidgetExtension target is missing; run: npm run ios:sync-live-activity-extension') unless target
abort('error: VexLiveActivityWidgetExtension has no VexLiveActivityWidget.swift source') unless target.source_build_phase.files_references.any? { |file| file.path == 'VexLiveActivityWidget.swift' }
abort('error: VexLiveActivityWidgetExtension has no VexVpnActivityAttributes.swift shared source') unless target.source_build_phase.files_references.any? { |file| file.path == 'VexVpnActivityAttributes.swift' }
app = project.targets.find { |item| item.name == 'VEX' }
abort('error: VEX target is missing') unless app
embed = app.copy_files_build_phases.find { |phase| phase.display_name == 'Embed App Extensions' }
abort('error: Embed App Extensions phase is missing') unless embed
abort('error: VexLiveActivityWidgetExtension.appex is not embedded into VEX') unless embed.files_references.any? { |file| file&.display_name == 'VexLiveActivityWidgetExtension.appex' }
puts 'VexLiveActivityWidgetExtension target is wired'
RUBY

echo "== AmneziaWG bridge =="
if [ -f "$ROOT_DIR/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/out/libwg-go.a" ]; then
  lipo -info "$ROOT_DIR/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/out/libwg-go.a"
else
  warn "AmneziaWG libwg-go.a is not built yet. Run: npm run ios:build-amneziawg-bridge"
fi
echo "iOS preflight finished"
