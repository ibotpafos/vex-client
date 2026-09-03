#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/vex-admission.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
swiftc -o "$BUILD/admission" \
  "$ROOT"/macos-native/Sources/VEXHelperCore/*.swift \
  "$ROOT/macos-native/Sources/VEXNativeMac/Services/NativeAwgBoolean.swift" \
  "$ROOT/macos-native/Tests/AdmissionHarness/main.swift" \
  -framework Security -framework SystemConfiguration -lbsm
"$BUILD/admission"
