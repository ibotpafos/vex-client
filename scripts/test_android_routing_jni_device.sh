#!/usr/bin/env bash
set -euo pipefail
[[ "${VEX_ANDROID_DEVICE_QA:-0}" == 1 ]] || { echo 'Set VEX_ANDROID_DEVICE_QA=1 for explicit USB device QA.' >&2; exit 2; }
[[ $# == 1 && -f "$1" ]] || { echo 'Usage: test_android_routing_jni_device.sh APK' >&2; exit 2; }
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${VEX_ANDROID_SDK_ROOT:?Set VEX_ANDROID_SDK_ROOT}"
java_home="${VEX_JAVA_HOME:?Set VEX_JAVA_HOME}"
adb="$sdk/platform-tools/adb"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/vex-routing-jni.XXXXXX")"
remote="/data/local/tmp/$(basename "$fixture")"
cleanup() {
  "$adb" -d shell rm -rf "$remote" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT
[[ "$("$adb" -d get-state)" == device ]] || { echo 'One authorized USB Android device is required.' >&2; exit 2; }
abi="$("$adb" -d shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in arm64-v8a|armeabi-v7a) ;; *) echo "Unsupported QA ABI: $abi" >&2; exit 2;; esac
unzip -p "$1" "lib/$abi/libwg-go.so" > "$fixture/libwg-go.so"
[[ -s "$fixture/libwg-go.so" ]] || { echo 'APK has no native routing library for this device.' >&2; exit 2; }
"$java_home/bin/javac" -source 8 -target 8 -d "$fixture" "$root_dir/scripts/qa-routing/NativeRoutingProbe.java"
mkdir "$fixture/dex"
JAVA_HOME="$java_home" "$sdk/build-tools/36.0.0/d8" --min-api 24 --lib "$sdk/platforms/android-36/android.jar" --output "$fixture/dex" "$fixture/NativeRoutingProbe.class"
"$adb" -d shell mkdir "$remote"
"$adb" -d push "$fixture/dex/classes.dex" "$remote/probe.dex" >/dev/null
"$adb" -d push "$fixture/libwg-go.so" "$remote/libwg-go.so" >/dev/null
"$adb" -d push "$1" "$remote/app.apk" >/dev/null
"$adb" -d shell dalvikvm -cp "$remote/probe.dex:$remote/app.apk" NativeRoutingProbe "$remote/libwg-go.so"
