#!/usr/bin/env bash
# Compile the real Expo VPN bridge against the iOS Simulator SDK. Fresh pods
# qualify this module fixture; they do not certify a reproducible full app build.
# No simulator is booted, no VPN is started, and no signing is requested.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "This SDK compilation requires macOS and Xcode." >&2; exit 1; }
for command_name in xcodebuild xcrun node ruby gem; do
  command -v "$command_name" >/dev/null || { echo "Missing iOS compile prerequisite: $command_name" >&2; exit 1; }
done
[[ -d "$root_dir/node_modules/expo" && -d "$root_dir/node_modules/react-native" ]] || {
  echo "Install the locked JavaScript dependencies with npm ci first." >&2
  exit 1
}
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null

fixture_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vex-ios-module.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
ruby_binary="$(command -v ruby)"
gem_dir="$fixture_dir/gems"
export GEM_HOME="$gem_dir"
export GEM_PATH="$gem_dir"
export GEM_SPEC_CACHE="$gem_dir/spec-cache"
export PATH="$gem_dir/bin:$PATH"
export COCOAPODS_DISABLE_STATS=true
"$ruby_binary" --version
# Use the selected Ruby for both gem installation and every pod/xcodeproj call;
# the runner's globally installed pod may belong to a different Ruby/version.
"$ruby_binary" -S gem install cocoapods --version 1.16.2 \
  --install-dir "$gem_dir" --bindir "$gem_dir/bin" --no-document
pod_binary="$gem_dir/bin/pod"
"$ruby_binary" -r cocoapods -r xcodeproj -e '
  abort("Expected isolated CocoaPods 1.16.2") unless Pod::VERSION == "1.16.2"
  path = Gem.loaded_specs.fetch("cocoapods").full_gem_path
  abort("CocoaPods must come from the fixture gem directory") unless path.start_with?(File.expand_path(ENV.fetch("GEM_HOME")) + "/")
  puts "Verified isolated CocoaPods #{Pod::VERSION}: #{path}"
'
"$ruby_binary" "$pod_binary" --version
project_dir="$fixture_dir/project"
mkdir -p "$project_dir/ios"
# Copy only the canonical files needed by CocoaPods. In particular, do not copy
# Podfile.lock: it still resolves Expo 56/RN 0.85, while npm installs Expo 57/RN 0.86.
cp "$root_dir/ios/Podfile" "$root_dir/ios/Podfile.properties.json" "$root_dir/ios/.xcode.env" "$project_dir/ios/"
cp -R "$root_dir/ios/VEX" "$root_dir/ios/VEX.xcodeproj" "$project_dir/ios/"
cp "$root_dir/package.json" "$root_dir/package-lock.json" "$root_dir/app.json" "$root_dir/app.config.ts" "$project_dir/"
for source_dir in node_modules modules assets; do
  ln -s "$root_dir/$source_dir" "$project_dir/$source_dir"
done

export CI=1
export EXPO_NO_TELEMETRY=1
export VEX_BUILD_PROFILE=development
export VEX_UPDATES_ENABLED=0

cd "$project_dir"
node -e 'for (const name of ["expo", "expo-modules-core", "react-native"]) console.log(`${name}: ${require(`${name}/package.json`).version}`)'
echo "Resolving fresh CocoaPods dependencies for the isolated module fixture."
"$ruby_binary" "$pod_binary" install --project-directory="$project_dir/ios"

# A future precompiled-module setting must not silently replace the new bridge
# or actor with a binary. Require both live files in the generated source phase.
"$ruby_binary" - "$project_dir/ios/Pods/Pods.xcodeproj" "$root_dir" <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open(ARGV[0])
target = project.targets.find { |candidate| candidate.name == 'VexVpn' }
abort('The generated Pods project has no VexVpn target') unless target
source_paths = target.source_build_phase.files_references.map { |file| File.realpath(file.real_path) }
%w[VexVpnModule.swift IosTunnelTransition.swift].each do |name|
  expected = File.realpath(File.join(ARGV[1], 'modules', 'vex-vpn', 'ios', name))
  abort("VexVpn must compile the live #{name}") unless source_paths.include?(expected)
  puts "Qualified live pod source: #{expected}"
end
RUBY

# Select the pod project rather than the app workspace. This compiles the live
# bridge, controller and ActivityKit sources with their real Expo dependencies,
# without building the app, its AmneziaWG/Go extension, or a release artifact.
# Target builds use SYMROOT/OBJROOT because -derivedDataPath requires a scheme.
compile_log="$fixture_dir/xcodebuild.log"
xcodebuild \
  -project "$project_dir/ios/Pods/Pods.xcodeproj" \
  -target VexVpn \
  -configuration Debug \
  -sdk iphonesimulator \
  -jobs 2 \
  "ARCHS=$(uname -m)" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  SKIP_INSTALL=YES \
  "SYMROOT=$fixture_dir/build/products" \
  "OBJROOT=$fixture_dir/build/intermediates" \
  build 2>&1 | tee "$compile_log"
"$ruby_binary" - "$compile_log" <<'RUBY'
trace = File.read(ARGV[0])
%w[VexVpnModule.swift IosTunnelTransition.swift].each do |name|
  abort("The fresh SDK build did not report compiling #{name}") unless trace.include?(name)
  puts "Verified SDK compilation trace: #{name}"
end
RUBY
echo "The actual VexVpn pod compiled against the iOS Simulator SDK without signing."
