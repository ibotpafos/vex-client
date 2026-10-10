#!/usr/bin/env bash
# Exercise Foundation probe cancellation and the real app-state recovery
# methods with isolated fake dependencies. macOS CI must still build the app.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-runtime-reliability.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
source_dir="$harness_dir/Sources/VEXNativeMac"
test_dir="$harness_dir/Tests/VEXNativeMacTests"
mkdir -p "$source_dir" "$test_dir"
native_dir="$root_dir/macos-native/Sources/VEXNativeMac"
app_state_source="${VEX_RUNTIME_APP_STATE_SOURCE:-$native_dir/Stores/VEXAppState.swift}"
helper_source="${VEX_RUNTIME_HELPER_SOURCE:-$native_dir/VEXHelperClient.swift}"
cp "$native_dir/Services/VpnEndpointProbe.swift" "$source_dir/"
cp "$root_dir/macos-native/Tests/VEXNativeMacTests/VpnEndpointProbeTests.swift" "$test_dir/"

# The fake dependency declarations surround the production methods verbatim;
# they never open the helper socket, write a profile, or contact the API.
python3 - "$app_state_source" \
    "$root_dir/macos-native/Tests/RuntimeRecoveryHarness/VpnRecoveryCallerTests.swift" \
    "$test_dir/VpnRecoveryCallerTests.swift" \
    "$helper_source" \
    "$root_dir/macos-native/Tests/RuntimeRecoveryHarness/VpnHelperCallerTests.swift" \
    "$test_dir/VpnHelperCallerTests.swift" <<'PY'
import pathlib
import re
import sys

for offset in range(1, len(sys.argv), 3):
    source = pathlib.Path(sys.argv[offset]).read_text()
    structural = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                        lambda match: " " * len(match.group()), source)
    fixture = pathlib.Path(sys.argv[offset + 1]).read_text()
    names = re.search(r"// VEX_RUNTIME_METHOD_NAMES: (.+)", fixture)
    assert names, "Missing production-method list"
    methods = []
    for name in names.group(1).split():
        declaration = re.search(r"^    (?:private )?func " + re.escape(name) + r"\(", source, re.M)
        assert declaration, f"Missing production method {name}"
        parameter = source.index("(", declaration.start())
        parameter_depth = 1
        parameter_end = parameter + 1
        while parameter_depth:
            parameter_depth += (structural[parameter_end] == "(") - (structural[parameter_end] == ")")
            parameter_end += 1
        opening = structural.index("{", parameter_end)
        depth = 1
        closing = opening + 1
        while depth:
            depth += (structural[closing] == "{") - (structural[closing] == "}")
            closing += 1
        methods.append(source[declaration.start():closing])
    marker = "    // VEX_RUNTIME_PRODUCTION_METHODS"
    assert fixture.count(marker) == 1, "Missing or ambiguous production-method marker"
    pathlib.Path(sys.argv[offset + 2]).write_text(fixture.replace(marker, "\n\n".join(methods)))
PY

for name in VpnRecoveryIntent VpnOperationOwnership; do
    cp "$native_dir/Services/$name.swift" "$source_dir/"
done
cp "$root_dir/macos-native/Tests/VEXNativeMacTests/VpnRecoveryIntentTests.swift" "$test_dir/"
cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "VEXRuntimeReliabilityHarness", platforms: [.macOS(.v15)], targets: [
    .target(name: "VEXNativeMac"),
    .testTarget(name: "VEXNativeMacTests", dependencies: ["VEXNativeMac"])
], swiftLanguageModes: [.v5])
SWIFT
swiftc -frontend -parse "$native_dir/Services/VpnAutopilotService.swift"
swiftc -frontend -parse "$native_dir/VEXHelperClient.swift"
swiftc -frontend -parse "$native_dir/Stores/VEXAppState.swift"
swift test --package-path "$harness_dir" -j 2 "$@"
