#!/usr/bin/env bash
set -euo pipefail

src_dir="$1"
config_path="$2"
_user_name="${3:-}"

helper_dir="/Library/Application Support/VEX VPN/helper"
plist="/Library/LaunchDaemons/app.vex.vpn.helper.plist"
helper_version_file="$src_dir/helper-version"
if [[ ! -r "$helper_version_file" ]]; then
  echo "Missing VPN resource: $helper_version_file" >&2
  exit 1
fi
helper_version="$(/usr/bin/sed -n '1{s/[[:space:]]//g;p;q;}' "$helper_version_file")"
if [[ -z "$helper_version" ]]; then
  echo "Bundled helper-version is empty." >&2
  exit 1
fi

umask 077

# 1. Validate bundled resources before touching the previous working helper.
for required in awg amneziawg-go vex-helper; do
  if [[ ! -x "$src_dir/$required" ]]; then
    echo "Missing VPN resource: $src_dir/$required" >&2
    exit 1
  fi

  if ! /usr/bin/codesign --verify --strict --verbose=2 "$src_dir/$required" >/dev/null 2>&1; then
    echo "Bundled $required is not code-signature valid. Rebuild VEX resources before installing." >&2
    exit 1
  fi

  host_arch="$(/usr/bin/uname -m)"
  archs="$(/usr/bin/lipo -archs "$src_dir/$required" 2>/dev/null || true)"
  if [[ " ${archs} " != *" ${host_arch} "* ]]; then
    echo "Bundled $required does not support ${host_arch} (archs: ${archs:-unknown})." >&2
    exit 1
  fi
done

/usr/bin/install -d -o root -g wheel -m 0755 "$helper_dir"
stage_dir="$(/usr/bin/mktemp -d "$helper_dir/.install.XXXXXX")"
cleanup_stage() {
  /bin/rm -rf "$stage_dir"
}
trap cleanup_stage EXIT

/usr/bin/install -o root -g wheel -m 0755 "$src_dir/awg" "$stage_dir/awg"
/usr/bin/install -o root -g wheel -m 0755 "$src_dir/amneziawg-go" "$stage_dir/amneziawg-go"
/usr/bin/install -o root -g wheel -m 0755 "$src_dir/vex-helper" "$stage_dir/vex-helper"
printf '%s\n' "$config_path" > "$stage_dir/config-path"
printf '%s\n' "$helper_version" > "$stage_dir/version"
/bin/chmod 0644 "$stage_dir/config-path" "$stage_dir/version"
/usr/sbin/chown root:wheel "$stage_dir/config-path" "$stage_dir/version"
/usr/bin/xattr -dr com.apple.quarantine "$stage_dir/awg" "$stage_dir/amneziawg-go" "$stage_dir/vex-helper" >/dev/null 2>&1 || true

for required in awg amneziawg-go vex-helper; do
  if ! /usr/bin/codesign --verify --strict --verbose=2 "$stage_dir/$required" >/dev/null 2>&1; then
    echo "Staged $required failed code-signature verification." >&2
    exit 1
  fi
done

# 2. Stop the old daemon only after the replacement is staged and verified.
/bin/launchctl bootout system/app.vex.vpn.helper >/dev/null 2>&1 || true
/usr/bin/killall vex-helper >/dev/null 2>&1 || true

# 3. Atomically replace helper resources.
/bin/mv -f "$stage_dir/awg" "$helper_dir/awg"
/bin/mv -f "$stage_dir/amneziawg-go" "$helper_dir/amneziawg-go"
/bin/mv -f "$stage_dir/vex-helper" "$helper_dir/vex-helper"
/bin/mv -f "$stage_dir/config-path" "$helper_dir/config-path"
/bin/mv -f "$stage_dir/version" "$helper_dir/version"
/bin/rmdir "$stage_dir"
trap - EXIT

/bin/chmod 0755 "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/vex-helper"
/bin/chmod 0644 "$helper_dir/config-path" "$helper_dir/version"
/usr/sbin/chown -R root:wheel "$helper_dir"

if ! /usr/bin/codesign --verify --strict --verbose=2 "$helper_dir/vex-helper" >/dev/null 2>&1; then
  echo "Installed vex-helper failed code-signature verification." >&2
  exit 1
fi

: > "$helper_dir/daemon.log"
: > "$helper_dir/daemon.err"
: > "$helper_dir/last.log"
/bin/chmod 0600 "$helper_dir/daemon.log" "$helper_dir/daemon.err" "$helper_dir/last.log"
/usr/sbin/chown root:wheel "$helper_dir/daemon.log" "$helper_dir/daemon.err" "$helper_dir/last.log"

# Clear stale transient state from older helpers before launchd starts the new daemon.
/bin/rm -f "$helper_dir/antileak.state" "$helper_dir/antileak.active" \
  "$helper_dir/operation.lock" "$helper_dir/utun.name" "$helper_dir/endpoint.txt" \
  "$helper_dir/protected_routes.state" "$helper_dir/protected-routes.txt"

# Clean up socket if exists.
/bin/rm -f /var/run/vex-helper.sock

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>app.vex.vpn.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper_dir/vex-helper</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$helper_dir/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>$helper_dir/daemon.err</string>
</dict>
</plist>
PLIST

/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"

/bin/launchctl bootstrap system "$plist"
/bin/launchctl kickstart -k system/app.vex.vpn.helper
