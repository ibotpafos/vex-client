# Repeatable routing leak scenarios

Run `bash scripts/test_vpn_leak_scenarios.sh` from this checkout. The script
uses the Go version pinned by native-routing/go.mod, shared Go caches and
temporary build files on mounted D, then executes
`TestLeakScenario*` with the race detector. All packets and sockets are in-memory
fixtures; no running VPN, route, DNS setting or firewall is touched.

`native-routing/leak_scenarios_test.go` exercises the real gVisor frontend and
AWG NetTUN with synthetic application traffic. A permitted DIRECT echo and a
DNS reply are positive controls, preventing a dead observer from proving safety.

The state matrix covers connecting, stopped AWG, revoked/expired DIRECT policy,
changed underlay and exhausted flow budget, with IPv4/IPv6 TCP/UDP packets.
DNS covers both TCP and UDP and both address families. Foreign DNS must never
fall back to physical DNS after AWG failure; revoked DIRECT names must also
remain blocked. A local empty SERVFAIL is allowed. Existing physical flows must
close on an underlay change. Capture survives these failures and is released
only by the explicit disconnect in the scenario.

These are bounded packet-routing regressions inspired by the state/DNS testing
approach in Mullvad's current `mullvadvpn-app/test`. No Mullvad code is copied.
They complement existing signed-policy and packet tests; they cannot qualify
OS-level kill switches, raw ICMP, platform VPN bypasses, daemon death, sleep or
signed physical-device releases. Preserve those separate acceptance gates.
