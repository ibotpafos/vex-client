#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/external/amnezia/amneziawg-apple/Sources/WireGuardKitGo"
OUTPUT_DIR="$BRIDGE_DIR/out"
OUTPUT="$OUTPUT_DIR/libwg-go.a"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ -d "$BRIDGE_DIR" ] || fail "AmneziaWG Apple bridge is missing at $BRIDGE_DIR"
command -v go >/dev/null || fail "go is required to build AmneziaWG iOS bridge"
command -v make >/dev/null || fail "make is required to build AmneziaWG iOS bridge"
command -v lipo >/dev/null || fail "lipo is required to produce universal libwg-go.a"

mkdir -p "$OUTPUT_DIR"
make -C "$BRIDGE_DIR" CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" build
[ -f "$OUTPUT" ] || fail "AmneziaWG bridge build finished without $OUTPUT"

echo "Built $OUTPUT"
