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
if ! /usr/bin/codesign --verify --deep --strict "$verified_app" >/dev/null 2>&1; then
  echo "Verified app snapshot failed code-signature validation." >&2
  exit 1
fi
pinned_team_id="${VEX_EXPECTED_TEAM_ID:-}"
snapshot_signature_details="$(/usr/bin/codesign -d --verbose=4 "$verified_app" 2>&1 || true)"
snapshot_identifier="$(
  /usr/bin/printf '%s\n' "$snapshot_signature_details" \
    | /usr/bin/sed -n 's/^Identifier=//p' \
    | /usr/bin/head -n 1
)"
snapshot_team_id="$(
  /usr/bin/printf '%s\n' "$snapshot_signature_details" \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
)"
if [[ "$snapshot_identifier" != "app.vex.vpn.native" \
      || -z "$pinned_team_id" \
      || "$snapshot_team_id" != "$pinned_team_id" ]]; then
  echo "Verified app snapshot identity does not match the pinned VEX application." >&2
  exit 1
fi
verified_resources="$verified_app/Contents/Resources/resources"
src_dir_real="$(cd "$src_dir" && /bin/pwd -P)"
verified_resources_real="$(cd "$verified_resources" && /bin/pwd -P)"
if [[ "$src_dir_real" != "$verified_resources_real" ]]; then
  echo "Helper resources must come from the verified app snapshot." >&2
  exit 1
fi
src_dir="$verified_resources_real"

helper_dir="/Library/Application Support/VEX VPN/helper"
plist="/Library/LaunchDaemons/app.vex.vpn.helper.plist"
antileak_anchor="com.vexguard.antileak"
antileak_anchor_file="/etc/pf.anchors/${antileak_anchor}"
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

helper_signature_details="$(/usr/bin/codesign -d --verbose=4 "$src_dir/vex-helper" 2>&1 || true)"
helper_team_id="$(
  /usr/bin/printf '%s\n' "$helper_signature_details" \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
)"
if [[ -n "$pinned_team_id" ]]; then
  if [[ "$helper_team_id" != "$pinned_team_id" ]]; then
    echo "Helper Team ID does not match pinned VEX_EXPECTED_TEAM_ID." >&2
    exit 1
  fi
  auth_environment_plist="
  <key>EnvironmentVariables</key>
  <dict>
    <key>VEX_EXPECTED_TEAM_ID</key>
    <string>$pinned_team_id</string>
  </dict>"
else
  echo "Pinned VEX_EXPECTED_TEAM_ID is required for privileged helper installation." >&2
  exit 1
fi
if [[ ! -x "$src_dir/awg-quick.sh" ]]; then
  echo "Missing VPN resource: $src_dir/awg-quick.sh" >&2
  exit 1
fi

# An app-only update must not needlessly restart the privileged daemon. Besides
# making installation feel slow, restarting a byte-for-byte identical helper
# can interrupt an otherwise healthy tunnel. We only take this path after the
# new resources have been verified above, and fall back to the complete
# fail-open replacement whenever anything about the current helper is unclear.
codesign_cdhash() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 \
    | /usr/bin/sed -n 's/^CDHash=//p' \
    | /usr/bin/head -n 1
}

same_signed_code() {
  local bundled="$1"
  local installed="$2"
  local bundled_cdhash
  local installed_cdhash

  [[ -f "$bundled" && -f "$installed" ]] || return 1
  bundled_cdhash="$(codesign_cdhash "$bundled")"
  installed_cdhash="$(codesign_cdhash "$installed")"
  [[ -n "$bundled_cdhash" && "$bundled_cdhash" == "$installed_cdhash" ]]
}

helper_resources_are_current() {
  [[ -S /var/run/vex-helper.sock ]] \
    && /bin/launchctl print system/app.vex.vpn.helper >/dev/null 2>&1 \
    && [[ -f "$helper_dir/version" ]] \
    && /usr/bin/cmp -s "$helper_version_file" "$helper_dir/version" \
    && /usr/bin/printf '%s\n' "$config_path" | /usr/bin/cmp -s - "$helper_dir/config-path" \
    || return 1

  for required in awg amneziawg-go awg-quick.sh vex-helper; do
    if [[ "$required" == "awg-quick.sh" ]]; then
      /usr/bin/cmp -s "$src_dir/$required" "$helper_dir/$required" || return 1
    else
      same_signed_code "$src_dir/$required" "$helper_dir/$required" || return 1
    fi
  done
}

helper_recovery_evidence_present() {
  for state_path in \
    "$helper_dir/utun.name" \
    "$helper_dir/endpoint.txt" \
    "$helper_dir/awg.pid" \
    "$helper_dir/antileak.state" \
    "$helper_dir/antileak.active"; do
    [[ -e "$state_path" ]] && return 0
  done

  /usr/bin/find /var/run/amneziawg -maxdepth 1 -name '*.name' -print -quit 2>/dev/null \
    | /usr/bin/grep -q .
}

helper_antileak_is_clear() {
  local pf_info
  local anchor_rules

  pf_info="$(/sbin/pfctl -s info 2>&1)" || return 1
  if /usr/bin/printf '%s\n' "$pf_info" | /usr/bin/grep -q "^Status: Disabled"; then
    return 0
  fi
  anchor_rules="$(/sbin/pfctl -a "$antileak_anchor" -sr 2>/dev/null)" || return 1
  ! /usr/bin/printf '%s\n' "$anchor_rules" | /usr/bin/grep -q '[^[:space:]]'
}

if helper_resources_are_current && helper_antileak_is_clear; then
  if helper_recovery_evidence_present; then
    echo "Recovery evidence is present; helper replacement is required."
  else
    echo "Helper resources unchanged; preserving active helper."
    exit 0
  fi
fi

/usr/bin/install -d -o root -g wheel -m 0755 "$helper_dir"
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
    for previous in awg amneziawg-go awg-quick.sh vex-helper config-path version; do
      if [[ -e "$rollback_dir/$previous" ]]; then
        /bin/cp -p "$rollback_dir/$previous" "$helper_dir/$previous"
      else
        /bin/rm -f "$helper_dir/$previous"
      fi
    done
    if [[ -e "$rollback_dir/helper.plist" ]]; then
      /bin/cp -p "$rollback_dir/helper.plist" "$plist"
      /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k system/app.vex.vpn.helper >/dev/null 2>&1 || true
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
/usr/bin/xattr -dr com.apple.quarantine "$stage_dir/awg" "$stage_dir/amneziawg-go" "$stage_dir/awg-quick.sh" "$stage_dir/vex-helper" >/dev/null 2>&1 || true

for required in awg amneziawg-go vex-helper; do
  if ! /usr/bin/codesign --verify --strict --verbose=2 "$stage_dir/$required" >/dev/null 2>&1; then
    echo "Staged $required failed code-signature verification." >&2
    exit 1
  fi
done

for previous in awg amneziawg-go awg-quick.sh vex-helper config-path version; do
  if [[ -e "$helper_dir/$previous" ]]; then
    /bin/cp -p "$helper_dir/$previous" "$rollback_dir/$previous"
  fi
done
if [[ -e "$plist" ]]; then
  /bin/cp -p "$plist" "$rollback_dir/helper.plist"
fi

# 2. Make the host fail-open before replacing a running helper. Older helper
# versions could leave the live PF anchor (and its persistent file) blocking
# after a failed shutdown, so the root installer clears and verifies PF first.
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
if helper_recovery_evidence_present; then
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
/bin/mv -f "$stage_dir/vex-helper" "$helper_dir/vex-helper"
/bin/mv -f "$stage_dir/config-path" "$helper_dir/config-path"
/bin/mv -f "$stage_dir/version" "$helper_dir/version"
/bin/rmdir "$stage_dir"

/bin/chmod 0755 "$helper_dir/awg" "$helper_dir/amneziawg-go" "$helper_dir/awg-quick.sh" "$helper_dir/vex-helper"
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
$auth_environment_plist
</dict>
</plist>
PLIST

/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"

/bin/launchctl bootstrap system "$plist"
/bin/launchctl kickstart -k system/app.vex.vpn.helper

if [[ "$recovery_needed" == "1" ]]; then
  for _ in {1..40}; do
    [[ -S /var/run/vex-helper.sock ]] && break
    /bin/sleep 0.1
  done
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
fi

install_complete=1
