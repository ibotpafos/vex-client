#!/bin/bash
# Render the actual SwiftUI client through its DEBUG-only renderer. Never open
# the ordinary app or invoke its helper/status/production startup paths.
set -euo pipefail

usage() {
    printf 'Usage: %s OUTPUT_DIRECTORY\n' "${0##*/}"
    printf 'Requires macOS and Swift 6.2+ from the selected Xcode toolchain.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 || -z "$1" ]]; then
    usage >&2
    exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'macOS is required to render the native SwiftUI reference.\n' >&2
    exit 69
fi
command -v python3 >/dev/null
command -v xcrun >/dev/null

reference_repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
reference_package="$reference_repository_root/macos-native"
reference_output="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")"
mkdir -p "$reference_output"
reference_scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/vex-macos-reference.XXXXXX")"
trap 'rm -rf "$reference_scratch_directory"' EXIT

# Use a separate build directory so a cached release executable cannot be
# selected accidentally. Kill a timed-out command and its child processes.
run_bounded() {
    python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
if not 1 <= seconds <= 1800:
    raise SystemExit("Command timeout must be between 1 and 1800 seconds.")
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    print("Native macOS reference command exceeded its time limit.", file=sys.stderr)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
PY
}

run_bounded 10 xcrun swift --version
run_bounded 900 xcrun swift build --package-path "$reference_package" \
    --scratch-path "$reference_scratch_directory/build" \
    --configuration debug --product VEXNativeMac
reference_binary_directory="$(run_bounded 30 xcrun swift build \
    --package-path "$reference_package" --scratch-path "$reference_scratch_directory/build" \
    --configuration debug --show-bin-path)"
reference_binary="$reference_binary_directory/VEXNativeMac"
if [[ ! -x "$reference_binary" ]]; then
    printf 'SwiftPM did not produce the DEBUG VEXNativeMac executable.\n' >&2
    exit 70
fi

python3 - "$reference_binary" "$reference_output" "$reference_scratch_directory" "$reference_package" <<'PY'
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
from pathlib import Path

binary, output, scratch, package = map(Path, sys.argv[1:])

# Verify the renderer is present before executing anything. A release binary
# ignores the preview flag, so its absence must fail without launching it.
symbols = subprocess.run(["xcrun", "nm", "-a", str(binary)],
                         check=True, capture_output=True, text=True, timeout=20)
demangled = subprocess.run(["xcrun", "swift-demangle"], input=symbols.stdout,
                          check=True, capture_output=True, text=True, timeout=20)
if "VEXNativeMac.VEXPreviewRenderer.render(" not in demangled.stdout:
    raise SystemExit("Executable has no DEBUG preview renderer; refusing to launch it.")

# These are existing SwiftUI screens with the app's own in-memory preview
# fixtures. Sign-in uses the existing signed-out flag and no authenticated data.
screens = [
    ("home", "home", {}, []),
    ("account", "account", {"VEX_PREVIEW_BILLING": "1"}, []),
    ("settings", "settings", {}, []),
    ("server-sidebar", "home", {"VEX_PREVIEW_SERVER_SIDEBAR": "1"}, []),
    ("signin", "home", {}, ["--signed-out-ui-preview"]),
]
environment = {key: value for key, value in os.environ.items()
               if not key.startswith("VEX_PREVIEW_")}
# Server-sidebar fixtures write AppStorage preferences. Keep Core Foundation's
# preferences in this disposable preview home without changing shell HOME.
preview_home = scratch / "preview-user"
preview_home.mkdir()
environment["CFFIXED_USER_HOME"] = str(preview_home)
manifest = {
    "renderer": "macos-native/Sources/VEXNativeMac/Support/VEXPreviewRenderer.swift",
    "rendering": "Actual AppKit NSHostingView hosting the existing SwiftUI screens, DEBUG fixtures, 2x PNG",
    "configuration": "debug",
    "screens": [],
    "omittedScreens": {"support": "The current macOS AppSection has home/account/settings; there is no macOS support panel."},
}
source_digest = hashlib.sha256()
for source in sorted((package / "Sources/VEXNativeMac").rglob("*")):
    if source.is_file():
        source_digest.update(str(source.relative_to(package)).encode())
        source_digest.update(source.read_bytes())
manifest["nativeSourceSha256"] = source_digest.hexdigest()

for name, section, fixtures, extra_args in screens:
    target = output / (name + ".png")
    target.unlink(missing_ok=True)
    command = [str(binary), "--render-ui-preview", section, str(target)] + extra_args
    # Request parsing exits the app initializer before normal scene startup;
    # the preview-only Account task guard also suppresses billing API refresh.
    screen_environment = environment | fixtures
    process = subprocess.Popen(command, env=screen_environment, start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        rendered_log, _ = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            rendered_log, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            rendered_log, _ = process.communicate()
        (output / (name + ".log")).write_text(rendered_log)
        raise SystemExit("Native preview renderer timed out for " + name)
    (output / (name + ".log")).write_text(rendered_log)
    if process.returncode != 0 or "rendered=" + str(target) not in rendered_log:
        raise SystemExit("Native preview renderer failed for " + name + "; inspect its log.")
    with target.open("rb") as image:
        header = image.read(24)
    expected_size = (700, 1160) if name == "server-sidebar" else (1840, 1160)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise SystemExit("Native preview did not produce a PNG for " + name)
    pixel_size = struct.unpack(">II", header[16:24])
    if pixel_size != expected_size:
        raise SystemExit("Unexpected native preview dimensions for " + name + ": " + str(pixel_size))
    manifest["screens"].append({
        "name": name,
        "file": target.name,
        "nativeSection": section,
        "pixelSize": pixel_size,
        "flags": ["--render-ui-preview", section] + extra_args,
        "fixtureEnvironment": fixtures,
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
    })
    print("Rendered actual macOS " + name + ": " + str(target))

(output / "reference-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY
