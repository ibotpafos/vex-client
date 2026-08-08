#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
target="${2:-}"
expected="${3:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

case "${mode}" in
  source)
    [ -d "${target}/.git" ] || fail "AmneziaWG Go checkout is missing: ${target}"
    actual_ref="$(git -C "${target}" rev-parse HEAD)"
    [ "${actual_ref}" = "${expected}" ] || fail "AmneziaWG Go ref mismatch: expected ${expected}, got ${actual_ref}"
    git -C "${target}" diff --quiet -- \
      || fail "AmneziaWG Go checkout differs from official upstream"

    receive="${target}/device/receive.go"
    send="${target}/device/send.go"
    constants="${target}/device/constants.go"
    # Official upstream timing contract: RekeyTimeout = time.Second * 5.
    grep -Fq 'len(elem.packet) == 0 || elem.packet[0] == 0' "${receive}" \
      || fail "official padded keepalive receive fix is missing"
    grep -Fq 'isKeepalive bool' "${send}" \
      || fail "official keepalive send marker is missing"
    grep -Fq 'elem.isKeepalive = true' "${send}" \
      || fail "official keepalive send classification is missing"
    grep -Fq 'if !elem.isKeepalive {' "${send}" \
      || fail "official keepalive data classification is missing"
    grep -Eq 'RekeyTimeout[[:space:]]*=[[:space:]]*time.Second \* 5' "${constants}" \
      || fail "RekeyTimeout differs from official upstream"
    grep -Eq 'MaxTimerHandshakes[[:space:]]*=[[:space:]]*90 / 5' "${constants}" \
      || fail "MaxTimerHandshakes differs from official upstream"
    grep -Eq 'RekeyTimeoutJitterMaxMs[[:space:]]*=[[:space:]]*334' "${constants}" \
      || fail "RekeyTimeoutJitterMaxMs differs from official upstream"
    ;;
  module)
    [ -f "${target}/go.mod" ] || fail "AmneziaWG Apple bridge go.mod is missing: ${target}"
    actual_version="$(cd "${target}" && go list -m -f '{{.Version}}' github.com/amnezia-vpn/amneziawg-go/v3)"
    [ "${actual_version}" = "${expected}" ] \
      || fail "AmneziaWG Apple bridge version mismatch: expected ${expected}, got ${actual_version}"
    ;;
  *)
    fail "usage: $0 source <checkout> <commit> | module <bridge-dir> <version>"
    ;;
esac
