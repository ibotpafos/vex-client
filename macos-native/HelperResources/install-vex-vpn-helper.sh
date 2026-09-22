#!/usr/bin/env bash
set -euo pipefail

src_dir="$1"
config_path="$2"
_user_name="${3:-}"
verified_app="${4:-}"

if [[ -z "$verified_app" || ! -d "$verified_app/Contents/Resources/resources" ]]; then
  echo "A root-owned verified app snapshot is required for helper installation." >&2
  exit 1
fi
# Fixed trust roots; environment overrides deliberately have no effect.
legacy_local_requirement='certificate leaf = H"f5817aa3c6875bee8828132e67a74422758f2834"'
local_requirement='certificate leaf = H"c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e"'
apple_requirement='anchor apple generic and certificate leaf[subject.OU] = "3JLW9XNU53"'
app_requirement="identifier \"app.vex.vpn.native\" and ($legacy_local_requirement or $local_requirement or ($apple_requirement))"
# Only the root-created private snapshot may supply executable installer inputs.
snapshot_parent="$(/usr/bin/dirname "$verified_app")"
if [[ "$EUID" != 0 || -L "$verified_app" || -L "$snapshot_parent" \
      || "$(/usr/bin/stat -f '%u:%Lp' "$snapshot_parent")" != "0:700" ]]; then
  echo "A private root-owned app snapshot is required." >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict -R="$app_requirement" "$verified_app" >/dev/null 2>&1; then
  echo "Verified app snapshot identity or signature does not match pinned VEX policy." >&2
  exit 1
fi
# All Mach-O resources must match the same signing branch as the enclosing app.
if /usr/bin/codesign --verify --strict -R="$legacy_local_requirement" "$verified_app" >/dev/null 2>&1; then
  resource_requirement="$legacy_local_requirement"
elif /usr/bin/codesign --verify --strict -R="$local_requirement" "$verified_app" >/dev/null 2>&1; then
  resource_requirement="$local_requirement"
else
  resource_requirement="$apple_requirement"
fi
verified_resources="$verified_app/Contents/Resources/resources"
src_dir_real="$(cd "$src_dir" && /bin/pwd -P)"
verified_resources_real="$(cd "$verified_resources" && /bin/pwd -P)"
if [[ "$src_dir_real" != "$verified_resources_real" ]]; then
  echo "Helper resources must come from the verified app snapshot." >&2
  exit 1
fi
src_dir="$verified_resources_real"

helper_root_dir="/Library/Application Support/VEX VPN"
helper_dir="$helper_root_dir/helper"
helper_tool_dir="/Library/PrivilegedHelperTools"
helper_tool="$helper_tool_dir/app.vex.vpn.helper"
legacy_helper="$helper_dir/vex-helper"
plist="/Library/LaunchDaemons/app.vex.vpn.helper.plist"
launchd_label="app.vex.vpn.helper"
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

  if ! /usr/bin/codesign --verify --strict --verbose=2 -R="$resource_requirement" "$src_dir/$required" >/dev/null 2>&1; then
    echo "Bundled $required is not code-signature valid. Rebuild VEX resources before installing." >&2
    exit 1
  fi

  # PackageKit may deny Mach-O inspection tools in its postinstall sandbox.
  # Universal-architecture coverage is therefore proven before packaging by
  # native_macos_production_preflight.sh. The pinned app signature above and
  # each nested signature still protect the exact resources installed here.
done

# The helper uses its compiled-in policy; no caller-controlled auth environment.
auth_environment_plist=""
if [[ ! -x "$src_dir/awg-quick.sh" ]]; then
  echo "Missing VPN resource: $src_dir/awg-quick.sh" >&2
  exit 1
fi

config_owner="$_user_name"
if [[ -z "$config_owner" ]] || ! /usr/bin/id "$config_owner" >/dev/null 2>&1; then
  echo "A valid local user is required for the VEX profile path." >&2
  exit 1
fi
config_owner_home="$(
  /usr/bin/dscl . -read "/Users/$config_owner" NFSHomeDirectory 2>/dev/null \
    | /usr/bin/awk '{print $2}'
)"
config_group="$(/usr/bin/id -gn "$config_owner")"
expected_config_path="$config_owner_home/.vex/vex.conf"
if [[ -z "$config_owner_home" ]] || [[ "$config_path" != "$expected_config_path" ]]; then
  echo "VEX profile path does not match the verified local user home." >&2
  exit 1
fi
config_dir="$(/usr/bin/dirname "$config_path")"
[[ ! -L "$config_dir" ]] || {
  echo "VEX profile directory must not be a symbolic link." >&2
  exit 1
}
if [[ -e "$config_dir" && ! -d "$config_dir" ]]; then
  echo "VEX profile path parent is not a directory." >&2
  exit 1
fi
/usr/bin/install -d -o "$config_owner" -g "$config_group" -m 0700 "$config_dir"
# install -d preserves an existing directory's owner and mode. Normalize only
# the dedicated VEX profile directory so the app can atomically refresh its
# profile; never recurse into the user's home or delete an existing profile.
/usr/sbin/chown "$config_owner:$config_group" "$config_dir"
/bin/chmod 0700 "$config_dir"
if [[ -e "$config_path" ]]; then
  if [[ -L "$config_path" || ! -f "$config_path" ]]; then
    echo "Existing VEX profile must be a regular file." >&2
    exit 1
  fi
  /usr/sbin/chown "$config_owner:$config_group" "$config_path"
  /bin/chmod 0600 "$config_path"
fi

/usr/bin/install -d -o root -g wheel -m 0755 "$helper_root_dir"
/usr/bin/install -d -o root -g wheel -m 0755 "$helper_dir"
/usr/bin/install -d -o root -g wheel -m 0755 "$helper_tool_dir"
# install -d does not repair owner/mode on an existing directory. Older VEX
# packages left the parent root:admin 0700, so the signed app could authenticate
# to the live socket but could not read the version/resources it uses to decide
# whether the helper is installed. Normalize only these root-owned code/resource
# directories; runtime logs remain 0600 and user configuration is untouched.
/usr/sbin/chown root:wheel "$helper_root_dir" "$helper_dir"
/bin/chmod 0755 "$helper_root_dir" "$helper_dir"
stage_dir="$(/usr/bin/mktemp -d "$helper_dir/.install.XXXXXX")"
rollback_dir="$(/usr/bin/mktemp -d /var/tmp/vex-helper-rollback.XXXXXX)"
replacement_started=0
install_complete=0

rollback_install() {
  local exit_status="$?"
  trap - EXIT
  /bin/rm -rf "$stage_dir"
  if [[ "$exit_status" != "0" && "$replacement_started" == "1" && "$install_complete" != "1" ]]; then
    echo "Helper replacement failed; restoring the previous helper." >&2
    /bin/launchctl bootout system/app.vex.vpn.helper >/dev/null 2>&1 || true
    /usr/bin/killall vex-helper >/dev/null 2>&1 || true
    for previous in awg amneziawg-go awg-quick.sh config-path version; do
      if [[ -e "$rollback_dir/$previous" ]]; then
        /bin/cp -p "$rollback_dir/$previous" "$helper_dir/$previous"
      else
        /bin/rm -f "$helper_dir/$previous"
      fi
    done
    if [[ -e "$rollback_dir/privileged-helper" ]]; then
      /bin/cp -p "$rollback_dir/privileged-helper" "$helper_tool"
    else
      /bin/rm -f "$helper_tool"
    fi
    if [[ -e "$rollback_dir/legacy-helper" ]]; then
      /bin/cp -p "$rollback_dir/legacy-helper" "$legacy_helper"
    else
      /bin/rm -f "$legacy_helper"
    fi
    if [[ -e "$rollback_dir/helper.plist" ]]; then
      /bin/cp -p "$rollback_dir/helper.plist" "$plist"
      /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k "system/$launchd_label" >/dev/null 2>&1 || true
    else
      /bin/rm -f "$plist"
    fi
    # Recovery must never restore a blocking persistent anchor.
    : > "$antileak_anchor_file"
    /sbin/pfctl -a "$antileak_anchor" -F all >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$rollback_dir"
  exit "$exit_status"
}
trap rollback_install EXIT

/usr/bin/install -o root -g wheel -m 0755 "$src_dir/awg" "$stage_dir/awg"
/usr/bin/install -o root -g wheel -m 0755 "$src_dir/amneziawg-go" "$stage_dir/amneziawg-go"
/usr/bin/install -o root -g wheel -m 0755 "$src_dir/awg-quick.sh" "$stage_dir/awg-quick.sh"
/usr/bin/install -o root -g wheel -m 0755 "$src_dir/vex-helper" "$stage_dir/vex-helper"
printf '%s\n' "$config_path" > "$stage_dir/config-path"
printf '%s\n' "$helper_version" > "$stage_dir/version"
/bin/chmod 0644 "$stage_dir/config-path" "$stage_dir/version"
/usr/sbin/chown root:wheel "$stage_dir/config-path" "$stage_dir/version"
for required in awg amneziawg-go vex-helper; do
  if ! /usr/bin/codesign --verify --strict --verbose=2 -R="$resource_requirement" "$stage_dir/$required" >/dev/null 2>&1; then
    echo "Staged $required failed code-signature verification." >&2
    exit 1
  fi
done

for previous in awg amneziawg-go awg-quick.sh config-path version; do
  if [[ -e "$helper_dir/$previous" ]]; then
    /bin/cp -p "$helper_dir/$previous" "$rollback_dir/$previous"
  fi
done
if [[ -e "$helper_tool" ]]; then
  /bin/cp -p "$helper_tool" "$rollback_dir/privileged-helper"
fi
if [[ -e "$legacy_helper" ]]; then
  /bin/cp -p "$legacy_helper" "$rollback_dir/legacy-helper"
fi
if [[ -e "$plist" ]]; then
  /bin/cp -p "$plist" "$rollback_dir/helper.plist"
fi

# 2. Make the host fail-open before replacing a running helper. Older helper
# versions could leave the live PF anchor (and its persistent file) blocking
# after a failed shutdown, so the root installer clears and verifies PF first.
antileak_anchor="com.vexguard.antileak"
antileak_anchor_file="/etc/pf.anchors/${antileak_anchor}"
anchor_tmp="$(/usr/bin/mktemp /etc/pf.anchors/.vex-antileak.XXXXXX)"
: > "$anchor_tmp"
/usr/sbin/chown root:wheel "$anchor_tmp"
/bin/chmod 0644 "$anchor_tmp"
/bin/mv -f "$anchor_tmp" "$antileak_anchor_file"
pf_info=""
if ! pf_info="$(/sbin/pfctl -s info 2>&1)"; then
  echo "Could not query PF status; keeping the current helper running." >&2
  exit 1
fi
pf_is_disabled=0
if /usr/bin/printf '%s\n' "$pf_info" | /usr/bin/grep -q "^Status: Disabled"; then
  pf_is_disabled=1
fi

if ! /sbin/pfctl -a "$antileak_anchor" -F all >/dev/null 2>&1; then
  if [[ "$pf_is_disabled" != "1" ]]; then
    echo "Could not clear the VEX anti-leak PF anchor; keeping the current helper running." >&2
    exit 1
  fi
fi

anchor_rules=""
anchor_query_status=0
# macOS emits unrelated ALTQ warnings on stderr even when the anchor is empty.
# Only rule output determines whether the anchor still blocks replacement.
anchor_rules="$(/sbin/pfctl -a "$antileak_anchor" -sr 2>/dev/null)" || anchor_query_status="$?"
if [[ "$anchor_query_status" != "0" && "$pf_is_disabled" != "1" ]]; then
  echo "Could not verify the VEX anti-leak PF anchor; keeping the current helper running." >&2
  exit 1
fi
if [[ "$anchor_query_status" == "0" ]] \
  && /usr/bin/printf '%s\n' "$anchor_rules" | /usr/bin/grep -q '[^[:space:]]'; then
  echo "VEX anti-leak PF anchor is still populated; refusing helper replacement." >&2
  exit 1
fi

recovery_needed=0
for state_path in \
  "$helper_dir/utun.name" \
  "$helper_dir/endpoint.txt" \
  "$helper_dir/awg.pid" \
  "$helper_dir/antileak.state" \
  "$helper_dir/antileak.active"; do
  if [[ -e "$state_path" ]]; then
    recovery_needed=1
    break
  fi
done
if /usr/bin/find /var/run/amneziawg -maxdepth 1 -name '*.name' -print -quit 2>/dev/null | /usr/bin/grep -q .; then
  recovery_needed=1
fi

if [[ -S /var/run/vex-helper.sock ]]; then
  shutdown_response="$(
    /usr/bin/printf 'shutdown\n' \
      | /usr/bin/nc -w 2 -U /var/run/vex-helper.sock 2>/dev/null \
      | /usr/bin/head -n 1 \
      || true
  )"
  # A shutdown acknowledgement only means that the old daemon accepted the
  # request.  It does not prove its asynchronous route/interface teardown has
  # completed.  Keep the pre-replacement recovery evidence so the replacement
  # helper performs and confirms the final fail-open cleanup.
fi

# Stop the old daemon only after the replacement is staged and PF is verified
# fail-open. If graceful shutdown failed, the new helper performs the retained
# DNS/route/interface recovery below.
replacement_started=1
/bin/launchctl bootout system/app.vex.vpn.helper >/dev/null 2>&1 || true
/usr/bin/killall vex-helper >/dev/null 2>&1 || true

# 3. Atomically replace helper resources.
/bin/mv -f "$stage_dir/awg" "$helper_dir/awg"
/bin/mv -f "$stage_dir/amneziawg-go" "$helper_dir/amneziawg-go"
/bin/mv -f "$stage_dir/awg-quick.sh" "$helper_dir/awg-quick.sh"
/bin/mv -f "$stage_dir/vex-helper" "$helper_tool"
/bin/mv -f "$stage_dir/config-path" "$helper_dir/config-path"
/bin/mv -f "$stage_dir/version" "$helper_dir/version"
/bin/rmdir "$stage_dir"

/bin/chmod 0755 "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/awg-quick.sh" "$helper_tool"
/bin/chmod 0644 "$helper_dir/config-path" "$helper_dir/version"
/usr/sbin/chown -R root:wheel "$helper_dir"
/usr/sbin/chown root:wheel "$helper_tool"
/bin/rm -f "$legacy_helper"

if ! /usr/bin/codesign --verify --strict --verbose=2 -R="$resource_requirement" "$helper_tool" >/dev/null 2>&1; then
  echo "Installed vex-helper failed code-signature verification." >&2
  exit 1
fi

: > "$helper_dir/daemon.log"
: > "$helper_dir/daemon.err"
: > "$helper_dir/last.log"
/bin/chmod 0600 "$helper_dir/daemon.log" "$helper_dir/daemon.err" "$helper_dir/last.log"
/usr/sbin/chown root:wheel "$helper_dir/daemon.log" "$helper_dir/daemon.err" "$helper_dir/last.log"

# Clear only the operation lock. Network recovery evidence is retained until
# the replacement helper confirms a complete fail-open teardown.
/bin/rm -f "$helper_dir/operation.lock"

# Clean up socket if exists.
/bin/rm -f /var/run/vex-helper.sock

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$launchd_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper_tool</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$helper_dir/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>$helper_dir/daemon.err</string>
$auth_environment_plist
</dict>
</plist>
PLIST

/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"

/bin/launchctl bootstrap system "$plist"
/bin/launchctl kickstart -k "system/$launchd_label"

helper_ready=0
for _ in {1..50}; do
  if [[ -S /var/run/vex-helper.sock ]] \
    && /bin/launchctl print "system/$launchd_label" >/dev/null 2>&1; then
    status_response="$(
      /usr/bin/printf 'status\n' \
        | /usr/bin/nc -w 2 -U /var/run/vex-helper.sock 2>/dev/null \
        | /usr/bin/head -n 1 \
        || true
    )"
    if [[ "$status_response" == state=* ]]; then
      helper_ready=1
      break
    fi
  fi
  /bin/sleep 0.1
done
if [[ "$helper_ready" != "1" ]]; then
  echo "Installed helper did not become ready for VPN commands." >&2
  exit 1
fi

installed_label="$(/usr/bin/plutil -extract Label raw -o - "$plist" 2>/dev/null || true)"
installed_program="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || true)"
if [[ "$installed_label" != "$launchd_label" || "$installed_program" != "$helper_tool" ]]; then
  echo "Installed LaunchDaemon label/program does not match the VEX privileged-helper contract." >&2
  exit 1
fi
if [[ ! -x "$helper_tool" ]] || ! /bin/launchctl print "system/$launchd_label" >/dev/null 2>&1; then
  echo "Installed privileged helper file or loaded LaunchDaemon assertion failed." >&2
  exit 1
fi

if [[ "$recovery_needed" == "1" ]]; then
  recovery_response="$(
    /usr/bin/printf 'down\n' \
      | /usr/bin/nc -w 5 -U /var/run/vex-helper.sock 2>/dev/null \
      | /usr/bin/head -n 1 \
      || true
  )"
  if [[ "$recovery_response" != "ok" ]]; then
    echo "Replacement helper did not confirm network recovery: ${recovery_response:-no response}" >&2
    exit 1
  fi
  recovery_status="$(
    /usr/bin/printf 'status\n' \
      | /usr/bin/nc -w 2 -U /var/run/vex-helper.sock 2>/dev/null \
      | /usr/bin/head -n 1 \
      || true
  )"
  if [[ "$recovery_status" != state=disconnected* ]]; then
    echo "Replacement helper did not confirm disconnected recovery state." >&2
    exit 1
  fi
fi

install_complete=1
