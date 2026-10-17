#!/usr/bin/env bash
# Explicit, elevated package installation only. Never called by tests or CI.
set -euo pipefail
[[ ${EUID} == 0 && $# == 2 ]] || { echo 'usage (root): install-routing-cli.sh <built-vex-awg> <sha256>' >&2; exit 77; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ "$2" =~ ^[0-9A-Fa-f]{64}$ ]] || exit 65
[[ $(sha256sum -- "$1" | cut -d' ' -f1) == "${2,,}" ]] || exit 65
for tool in nft ip awg awg-quick systemctl resolvectl python3 getent; do command -v "$tool" >/dev/null || exit 69; done
if ! getent passwd _vexvpn >/dev/null; then useradd --system --user-group --home-dir /var/empty --shell /usr/sbin/nologin _vexvpn; fi
identity=$(getent passwd _vexvpn)
IFS=: read -r _ _ uid gid _ directory shell <<< "$identity"
[[ "$uid" =~ ^[0-9]+$ && "$uid" -gt 0 && "$uid" -lt 1000 && "$gid" -gt 0 && "$directory" == /var/empty && "$shell" == /usr/sbin/nologin ]] || exit 77
install -d -m 755 -o root -g root /usr/libexec/vex
install -m 755 -o root -g root "$1" /usr/libexec/vex/vex-awg
for file in vex-routing-up vex-routing-activate vex-routing-refresh; do install -m 755 -o root -g root "$source_dir/$file" "/usr/libexec/vex/$file"; done
for file in vex-routing.service vex-routing-refresh.service vex-routing-refresh.timer; do install -m 644 -o root -g root "$source_dir/$file" "/etc/systemd/system/$file"; done
systemctl daemon-reload
# Start is an explicit connection action through vex-vpn-linux-helper.
