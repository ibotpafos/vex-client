# Native Russian DIRECT routing

VEX captures IPv4 and IPv6 defaults, then chooses DIRECT or the AWG NetTUN in
userspace. Country lists never become thousands of OS routes. Android retains
two Builder routes; desktop owners retain their existing route/DNS journals.

The engine accepts only `vex-routing-policy/v2`, signed by the public P-256
keyring embedded in the distribution. It verifies exact payload bytes, platform,
RU region, bounded CIDRs/domain rules, source freshness, expiry and a replay
floor derived from the previous verified signature. Invalid authority grants no
Russian DIRECT exceptions. Expiry closes DIRECT flows without releasing capture.
Verified cache history survives full-tunnel or missing-authority startup. Expired
DNS entries free bounded memory without reassigning old application identities.

Russian names on shared CDN addresses receive unique FakeIP identities. The real
CDN address is not globally bypassed. Russian DNS uses qualified encrypted DoH;
other DNS and TCP/UDP use AWG, with no physical fallback. Application DoH/ECH
cannot supply a new hostname exception; unrecognized destinations follow the
signed IP policy. Unknown/stale FakeIP addresses are rejected.

The only built-in control exception is TCP/443 for `vexguard.app` and
`www.vexguard.app` through the same per-host identity. The fixed recovery origin
serves public signed policy data at `/v1/vpn/routing-policy/public?platform=...`;
it supplies no account/device/profile keys or VPN access. The engine refreshes
independently of the UI, normally every six hours, retrying failures every five
minutes. A failed refresh preserves the last valid generation until expiry.

Every physical socket is qualified before connect: Android VpnService protection
plus Network binding; Apple bound interface; Windows/Linux unicast interface.
Binding failure rejects egress. Underlay changes close prior DIRECT sockets.
macOS PF permits only the non-login `_vexvpn` daemon UID. Windows firewall v4
permits only the pinned signed engine path on the selected physical NIC and
keeps default Block; versions 2/3 remain recoverable. Recovery/retirement stops
AWG without releasing capture. Explicit disconnect confirms engine stop before
network restoration.

Android/Apple SDK patches are additive to pinned AWG 3.1 sources. The shared Go
module uses the existing MIT AWG NetTUN and Apache-2.0 gVisor implementation.
Routing builds use Go 1.26.10 and `golang.org/x/net` v0.60.0, including the
malformed DNS response and HTTP/2 security fixes. Android retains the upstream
boottime runtime patch and verifies the bundled compiler archive SHA-256.
`policy-signing-keys.json` contains public keys only. Key rotation must update
all sealed engine builds together with the packaged signing keyring. SDK native
builds include the shared routing sources on every incremental build.

iOS retires an activation before stopping crypto; an on-demand restart keeps
capture without replaying its old peer keys. macOS retains requested protection
on bootstrap, watchdog, filter-arm and stop failures. Transport fallback keeps
the requested routing mode. Linux retirement survives systemd restart.

## Isolated verification

Run `go test -race -timeout 45s ./...` here. Packet fixtures use in-memory TUN,
virtual peers and fake physical sockets; they do not change a running VPN, OS
routes, DNS or firewall. They cover TCP, UDP/QUIC, IPv6, shared-CDN identity,
control-port confinement, unavailable AWG, retained capture and invalid signing
scope, cache replay floors, memory reclamation and clock-driven expiry (11 tests).
The pure Foundation checks in `scripts/test_ios_routing_suspend.sh` and fake
macOS helper checks in `scripts/test_awg31_macos_admission.sh` exercise protected
stop/failure paths without accessing the system VPN. Windows Core checks accept
`--native-routing-regression`; PowerShell was parsed without executing scripts.
SDK libraries and desktop executables can be cross-built without running
them. Installer, TUN daemon and physical acceptance scripts require an explicit
operator action and an isolated target.

## Release acceptance

Source/build evidence does not establish physical leak protection. Before rollout:

- Build the real iOS extension with full Xcode and verify its memory budget,
  background/restart behavior, IPv6-only/NAT64 and includeAllNetworks semantics.
  Consumer on-demand is not an MDM Always-On guarantee after every OS failure.
- Build the Windows XAML application on Windows; verify signed install, upgrade,
  rollback, uninstall, service/controller death and ordinary app physical egress.
- Verify Android API 28/32/33+ routing/Binder budget and OS Always-On/lockdown,
  and macOS dedicated UID, PF, DNS and underlay recovery on isolated devices.
- Linux has a protected CLI/helper integration, not a published native GUI.
  Stage the Go engine explicitly with `packaging/linux/install-routing-cli.sh`
  and qualify nftables/systemd-resolved/network change in a disposable namespace.

No installed clients or production state are changed by building this source.
