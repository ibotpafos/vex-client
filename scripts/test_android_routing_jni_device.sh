#!/usr/bin/env bash
set -euo pipefail
[[ "${VEX_ANDROID_DEVICE_QA:-0}" == 1 ]] || { echo 'Set VEX_ANDROID_DEVICE_QA=1 for explicit USB device QA.' >&2; exit 2; }
[[ $# == 1 && -f "$1" ]] || { echo 'Usage: test_android_routing_jni_device.sh APK' >&2; exit 2; }
[[ -n "${VEX_ANDROID_QA_SERIAL:-}" && -n "${VEX_ANDROID_QA_MODEL:-}" ]] || { echo 'Set the explicitly approved VEX_ANDROID_QA_SERIAL and VEX_ANDROID_QA_MODEL.' >&2; exit 2; }
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${VEX_ANDROID_SDK_ROOT:?Set VEX_ANDROID_SDK_ROOT}"
java_home="${VEX_JAVA_HOME:?Set VEX_JAVA_HOME}"
adb="$sdk/platform-tools/adb"
[[ "$("$adb" -s "$VEX_ANDROID_QA_SERIAL" get-state 2>/dev/null)" == device ]] || { echo 'The exact approved Android device must be connected and authorized.' >&2; exit 2; }
[[ "$("$adb" -s "$VEX_ANDROID_QA_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')" == "$VEX_ANDROID_QA_MODEL" ]] || { echo 'The approved Android model does not match.' >&2; exit 2; }
[[ -d "${TMPDIR:-}" && "$(df -P /Volumes/D | awk 'NR == 2 {print $NF}')" == /Volumes/D ]] || { echo 'A mounted D volume and explicit TMPDIR are required.' >&2; exit 2; }
physical_tmp="$(cd "$TMPDIR" && pwd -P)"
case "$physical_tmp" in /Volumes/D/*) ;; *) echo 'TMPDIR must physically reside on D.' >&2; exit 2;; esac
umask 077
fixture="$(mktemp -d "$physical_tmp/vex-routing-jni.XXXXXX")"
remote="/data/local/tmp/$(basename "$fixture")"
remote_created=0
device() { "$adb" -s "$VEX_ANDROID_QA_SERIAL" "$@" 2> "$fixture/adb.stderr"; }
cleanup() {
  if [[ "$remote_created" == 1 ]]; then device shell rm -rf "$remote" >/dev/null 2>&1 || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Djava.io.tmpdir=\"$physical_tmp\""
abi="$(device shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in arm64-v8a|armeabi-v7a) ;; *) echo "Unsupported QA ABI: $abi" >&2; exit 2;; esac
unzip -p "$1" "lib/$abi/libwg-go.so" > "$fixture/libwg-go.so"
[[ -s "$fixture/libwg-go.so" ]] || { echo 'APK has no native routing library for this device.' >&2; exit 2; }
"$java_home/bin/javac" -source 8 -target 8 -d "$fixture" "$root_dir/scripts/qa-routing/NativeRoutingProbe.java"
mkdir "$fixture/dex"
JAVA_HOME="$java_home" "$sdk/build-tools/36.0.0/d8" --min-api 24 --lib "$sdk/platforms/android-36/android.jar" --output "$fixture/dex" "$fixture/NativeRoutingProbe.class"
device shell mkdir "$remote"
remote_created=1
device push "$fixture/dex/classes.dex" "$remote/probe.dex" >/dev/null
device push "$fixture/libwg-go.so" "$remote/libwg-go.so" >/dev/null
device push "$1" "$remote/app.apk" >/dev/null
device shell dalvikvm -cp "$remote/probe.dex:$remote/app.apk" NativeRoutingProbe "$remote/libwg-go.so"
