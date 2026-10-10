#!/usr/bin/env bash
# Build the canonical app, VPN and widget extensions, and JavaScript bundle in
# an owned temporary tree. No signing, simulator boot, archive or upload occurs.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
lock_mode=locked
case "${1:-}" in
  '') [[ $# == 0 ]] ;;
  --regenerate-lock) [[ $# == 1 ]]; lock_mode=regenerate ;;
  *) echo "Usage: $0 [--regenerate-lock]" >&2; exit 1 ;;
esac
[[ "$(uname -s)" == Darwin ]] || { echo "This SDK build requires macOS and Xcode." >&2; exit 1; }
for command_name in xcodebuild xcrun node ruby gem go make git tar; do
  command -v "$command_name" >/dev/null || { echo "Missing iOS build prerequisite: $command_name" >&2; exit 1; }
done
[[ -d "$root_dir/node_modules/expo" && -d "$root_dir/node_modules/react-native" ]] || {
  echo "Install the locked JavaScript dependencies with npm ci first." >&2
  exit 1
}
[[ "$(go env GOVERSION)" == go1.26.9 ]] || { echo "Use the pinned Go 1.26.9 toolchain." >&2; exit 1; }
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang_binary="$(xcrun --sdk iphonesimulator --find clang)"
fixture_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vex-ios-app.XXXXXX")"
cleanup_fixture() {
  local primary_status=$?
  trap - EXIT
  # Go module cache directories are read-only by default. Only this owned cache
  # needs permissions restored; source packages and toolchains stay untouched.
  if [[ -d "$fixture_dir/go-mod" ]]; then
    chmod -R u+w "$fixture_dir/go-mod" || true
  fi
  rm -rf "$fixture_dir" || { if [[ "$primary_status" == 0 ]]; then primary_status=1; fi; }
  exit "$primary_status"
}
trap cleanup_fixture EXIT

ruby_binary="$(command -v ruby)"
gem_dir="$fixture_dir/gems"
export GEM_HOME="$gem_dir" GEM_PATH="$gem_dir" GEM_SPEC_CACHE="$gem_dir/spec-cache"
export PATH="$gem_dir/bin:$PATH"
export COCOAPODS_DISABLE_STATS=true
"$ruby_binary" --version
"$ruby_binary" -S gem install cocoapods --version 1.16.2 \
  --install-dir "$gem_dir" --bindir "$gem_dir/bin" --no-document
pod_binary="$gem_dir/bin/pod"
"$ruby_binary" -r cocoapods -r xcodeproj -e '
  abort("Expected isolated CocoaPods 1.16.2") unless Pod::VERSION == "1.16.2"
  path = Gem.loaded_specs.fetch("cocoapods").full_gem_path
  abort("CocoaPods must come from the fixture gem directory") unless path.start_with?(File.expand_path(ENV.fetch("GEM_HOME")) + "/")
  puts "Verified isolated CocoaPods #{Pod::VERSION}: #{path}"
'

project_dir="$fixture_dir/project"
# Only tracked canonical build inputs are copied: local credentials, Pods,
# stale external archives and other platform build outputs cannot enter it.
# Expo's native precompile phases write into installed package directories, so
# those dependencies also belong to the fixture rather than the source checkout.
copy_canonical_project() {
  local destination="$1"
  mkdir -p "$destination"
  (
    cd "$root_dir"
    git ls-files -z -- ios scripts modules assets app src patches ':(top,glob)*' \
      | tar --null -T - -cf - | tar -xf - -C "$destination"
  )
  cp -R "$root_dir/node_modules" "$destination/node_modules"
  mkdir -p "$destination/.metro-cache" "$destination/.metro-file-map-cache"
}
copy_canonical_project "$project_dir"
export CI=1 EXPO_NO_TELEMETRY=1 VEX_BUILD_PROFILE=development VEX_UPDATES_ENABLED=0
export GOTOOLCHAIN=local GOENV=off GOMAXPROCS=2 GOFLAGS=-p=2
export GOMODCACHE="$fixture_dir/go-mod" GOCACHE="$fixture_dir/go-build"

cd "$project_dir"
node -e 'for (const name of ["expo", "expo-modules-core", "react-native"]) console.log(`${name}: ${require(`${name}/package.json`).version}`)'
pod_arguments=(install --project-directory="$project_dir/ios")
if [[ "$lock_mode" == regenerate ]]; then
  rm "$project_dir/ios/Podfile.lock"
  echo "Regenerating the canonical iOS lock in the temporary fixture."
else
  pod_arguments+=(--deployment)
  echo "Installing the tracked iOS lock with CocoaPods deployment enforcement."
fi
"$ruby_binary" "$pod_binary" "${pod_arguments[@]}"
"$ruby_binary" - "$project_dir/ios/Pods/Local Podspecs/ExpoModulesCore.podspec.json" <<'RUBY'
require 'json'
spec = JSON.parse(File.read(ARGV.fetch(0)))
abort('ExpoModulesCore must use its supported source build for a relocatable lock') unless spec['static_framework'] == true && spec['source_files'] && !spec['vendored_frameworks']
puts 'Verified canonical ExpoModulesCore source-build selection.'
RUBY
if [[ "$lock_mode" == locked ]]; then
  cmp "$root_dir/ios/Podfile.lock" "$project_dir/ios/Podfile.lock"
  echo "Verified tracked Podfile.lock was preserved exactly by deployment installation."
else
  # A lock captured at one absolute path must deploy unchanged at another.
  # Start from canonical dependencies again, excluding the first install's Pods
  # and generated npm-package outputs, to expose path-dependent podspec checksums.
  relocated_project="$fixture_dir/relocated-project"
  copy_canonical_project "$relocated_project"
  cp "$project_dir/ios/Podfile.lock" "$relocated_project/ios/Podfile.lock"
  (
    cd "$relocated_project"
    "$ruby_binary" "$pod_binary" install --project-directory="$relocated_project/ios" --deployment
  )
  cmp "$project_dir/ios/Podfile.lock" "$relocated_project/ios/Podfile.lock"
  cmp "$project_dir/ios/Pods/Local Podspecs/ExpoModulesCore.podspec.json" \
    "$relocated_project/ios/Pods/Local Podspecs/ExpoModulesCore.podspec.json"
  echo "Verified fresh second-location deployment preserved the generated lock and ExpoModulesCore spec exactly."

  # Text only: the generated lock is reviewable/importable from the job log.
  # Input hashes and the payload hash prevent importing a lock from another head.
  "$ruby_binary" - "$project_dir" <<'RUBY'
require 'base64'
require 'digest'
require 'json'
$stdout.sync = true
root = ARGV.fetch(0)
lock = File.binread(File.join(root, 'ios/Podfile.lock'))
abort('Generated Podfile.lock exceeds the 256 KiB text-export bound') if lock.bytesize > 256 * 1024
inputs = %w[package.json package-lock.json app.json app.config.ts ios/Podfile ios/Podfile.properties.json modules/vex-vpn/ios/VexVpn.podspec]
inputs.concat(Dir.chdir(root) { Dir.glob('modules/**/{package.json,expo-module.config.json,*.podspec}') })
inputs.concat(Dir.chdir(root) { Dir.glob('patches/**/*').select { |path| File.file?(path) } })
metadata = {
  'sha256' => Digest::SHA256.hexdigest(lock),
  'bytes' => lock.bytesize,
  'cocoapods' => '1.16.2',
  'github_sha' => ENV['GITHUB_SHA'],
  'inputs' => inputs.uniq.sort.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
}
puts "VEX_IOS_POD_LOCK_METADATA #{JSON.generate(metadata)}"
puts 'VEX_IOS_POD_LOCK_BASE64_BEGIN'
Base64.strict_encode64(lock).scan(/.{1,120}/).each { |line| puts "VEX_IOS_POD_LOCK_BASE64 #{line}" }
puts 'VEX_IOS_POD_LOCK_BASE64_END'
RUBY
fi

# Retain the canonical Debug configuration while forcing its real JS bundle;
# the project sources this fixture-only file after its SKIP_BUNDLING assignment.
cat > "$project_dir/ios/.xcode.env.local" <<'ENVFILE'
export NODE_BINARY=$(command -v node)
unset SKIP_BUNDLING
export FORCE_BUNDLING=1
export EXTRA_PACKAGER_ARGS='--max-workers 2'
ENVFILE

AMNEZIAWG_EXTERNAL_DIR="$project_dir/external/amnezia" \
  AMNEZIAWG_APPLE_REFERENCE_REPO= \
  bash "$project_dir/scripts/bootstrap_amneziawg_ios.sh"
bridge_dir="$project_dir/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo"
# The pinned upstream Makefile has no simulator GOOS entry. Pass the explicit
# simulator target to make without modifying upstream source or a shared archive.
make -C "$bridge_dir" \
  "CONFIGURATION_BUILD_DIR=$bridge_dir/out" \
  "CONFIGURATION_TEMP_DIR=$fixture_dir/go-bridge" \
  PLATFORM_NAME=iphonesimulator ARCHS=arm64 GOOS_iphonesimulator=ios \
  "SDKROOT=$simulator_sdk" "CC=$clang_binary" \
  "CFLAGS_PREFIX=-target arm64-apple-ios16.4-simulator -isysroot $simulator_sdk -arch" \
  build
xcrun lipo "$bridge_dir/out/libwg-go.a" -verify_arch arm64
xcrun otool -l "$bridge_dir/out/libwg-go.a" > "$fixture_dir/bridge-load-commands.txt"
"$ruby_binary" - "$fixture_dir/bridge-load-commands.txt" <<'RUBY'
trace = File.read(ARGV.fetch(0))
platforms = trace.scan(/^\s*platform\s+(\S+)/).flatten
abort('The Go bridge must contain only iOS Simulator platform load commands') if platforms.empty? || platforms.any? { |platform| !%w[7 IOSSIMULATOR].include?(platform) }
puts 'Verified fresh arm64 iOS Simulator Go bridge platform.'
RUBY

"$ruby_binary" - "$project_dir" "$root_dir" <<'RUBY'
require 'digest'
require 'xcodeproj'
fixture, canonical = ARGV
pods = Xcodeproj::Project.open(File.join(fixture, 'ios/Pods/Pods.xcodeproj'))
pod = pods.targets.find { |target| target.name == 'VexVpn' }
abort('Missing real VexVpn pod target') unless pod
source_paths = pod.source_build_phase.files_references.map { |file| File.realpath(file.real_path) }
%w[VexVpnModule.swift IosTunnelTransition.swift].each do |name|
  relative = File.join('modules/vex-vpn/ios', name)
  path = File.realpath(File.join(fixture, relative))
  abort("Missing live #{name} source") unless source_paths.include?(path)
  abort("Copied #{name} differs from canonical source") unless File.binread(path) == File.binread(File.join(canonical, relative))
  puts "Qualified canonical pod source: #{relative} sha256=#{Digest::SHA256.file(path).hexdigest}"
end
project = Xcodeproj::Project.open(File.join(fixture, 'ios/VEX.xcodeproj'))
app = project.targets.find { |target| target.name == 'VEX' }
abort('Missing canonical app target') unless app
%w[VexVpnTunnel VexLiveActivityWidgetExtension].each do |name|
  extension = project.targets.find { |target| target.name == name }
  abort("Missing #{name} app dependency") unless extension && app.dependencies.any? { |dependency| dependency.target == extension }
  abort("Missing embedded #{name}") unless app.copy_files_build_phases.any? { |phase| phase.files_references.include?(extension.product_reference) }
end
RUBY

compile_log="$fixture_dir/xcodebuild.log"
xcodebuild \
  -workspace "$project_dir/ios/VEX.xcworkspace" \
  -scheme VEX -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$fixture_dir/derived-data" -jobs 2 \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  build 2>&1 | tee "$compile_log"
app_dir="$fixture_dir/derived-data/Build/Products/Debug-iphonesimulator/VEX.app"
for relative in VEX PlugIns/VexVpnTunnel.appex/VexVpnTunnel PlugIns/VexLiveActivityWidgetExtension.appex/VexLiveActivityWidgetExtension main.jsbundle; do
  [[ -s "$app_dir/$relative" ]] || { echo "Missing full iOS app output: $relative" >&2; exit 1; }
  echo "Verified full iOS app output: $relative"
done
"$ruby_binary" - "$compile_log" <<'RUBY'
trace = File.read(ARGV.fetch(0))
abort('Missing actual source compilation of ExpoModulesCore') unless trace.lines.any? { |line| line.include?('SwiftCompile') && line.include?("in target 'ExpoModulesCore' from project 'Pods'") }
puts 'Verified full-app SDK source compilation: ExpoModulesCore.'
%w[VexVpnModule.swift IosTunnelTransition.swift AppDelegate.swift PacketTunnelProvider.swift VexLiveActivityWidget.swift].each do |name|
  abort("Missing actual SwiftCompile trace for #{name}") unless trace.lines.any? { |line| line.include?('SwiftCompile') && line.include?(name) }
  puts "Verified full-app SDK compilation trace: #{name}"
end
RUBY
echo "Canonical unsigned VEX simulator app, both extensions and JS bundle built with lock mode: $lock_mode."
