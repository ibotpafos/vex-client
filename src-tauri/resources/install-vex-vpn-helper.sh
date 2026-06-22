#!/usr/bin/env bash
set -euo pipefail

src_dir="$1"
config_path="$2"
user_name="$3"

helper_dir="/Library/Application Support/VEX VPN/helper"
plist="/Library/LaunchDaemons/app.vex.vpn.helper.plist"

# 1. Unload the LaunchDaemon first so launchd stops monitoring and won't restart it
launchctl bootout system/app.vex.vpn.helper >/dev/null 2>&1 || true

# 2. Force terminate any running helper instance
killall vex-helper >/dev/null 2>&1 || true

# 3. Validate bundled resources before removing the previous working helper.
for required in awg amneziawg-go vex-helper; do
  if [ ! -f "$src_dir/$required" ]; then
    echo "Missing VPN resource: $src_dir/$required" >&2
    exit 1
  fi
done

# 4. Clean up old binary inodes to prevent 'Text file busy' errors on copy
mkdir -p "$helper_dir"
rm -f "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/vex-helper" || true

# 5. Copy new binaries and configuration
cp "$src_dir/awg" "$helper_dir/awg"
cp "$src_dir/amneziawg-go" "$helper_dir/amneziawg-go"
cp "$src_dir/vex-helper" "$helper_dir/vex-helper"
printf '%s\n' "$config_path" > "$helper_dir/config-path"
printf '17\n' > "$helper_dir/version"

chmod 755 "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/vex-helper"
chmod 644 "$helper_dir/config-path" "$helper_dir/version"
chown -R root:wheel "$helper_dir"
xattr -dr com.apple.quarantine "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/vex-helper" >/dev/null 2>&1 || true

# Clean up socket if exists
rm -f /var/run/vex-helper.sock

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

chown root:wheel "$plist"
chmod 644 "$plist"

launchctl bootstrap system "$plist"
launchctl kickstart -k system/app.vex.vpn.helper
