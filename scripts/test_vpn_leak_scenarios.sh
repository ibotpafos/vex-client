#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d /Volumes/D && -d /Volumes/D/VEX-CI/cache ]] || { echo 'Mounted D and CI cache are required' >&2; exit 2; }
export GOCACHE=/Volumes/D/VEX-CI/cache/go-build
export GOMODCACHE=/Volumes/D/VEX-CI/cache/go-mod
export GOTMPDIR=/Volumes/D/VEX-CI/cache/go/tmp
export TMPDIR="${GOTMPDIR}"
mkdir -p "${GOTMPDIR}"
cd "${root_dir}/native-routing"
go_version="$(awk '$1 == "go" {print $2; exit}' go.mod)"
[[ "${go_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Pinned Go version is required' >&2; exit 2; }
export GOTOOLCHAIN="go${go_version}"
# All fixtures are in memory: this command does not access the active VPN.
exec go test -race -count=1 -timeout 90s -run '^TestLeakScenario' .
