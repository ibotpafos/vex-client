# Isolated Windows VPN acceptance

Run the wrapper only on a fresh disposable GitHub-hosted **Windows x64** runner:

```powershell
./native-windows/scripts/invoke-vpn-acceptance.ps1 -DisposableRunner `
  -ResultPath temp/vex-windows/vpn-acceptance-x64.json
```

Install .NET SDK `10.0.x` and Go `1.26.6` first. The wrapper downloads the
official `amnezia-vpn/amneziawg-windows-client` **3.1.0** amd64 MSI and checks
SHA256 `a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b`.
Administrative MSI extraction supplies its actual `amneziawg.exe` and Wintun
0.14.1 DLL; the full vendor GUI is never installed. The Go peer pins the same
`amneziawg-go/v3 v3.1.20260814` as that qualified CLI, with a checked-in `go.sum`.

The C# harness references the production VEX Core and Service projects. It signs
an ephemeral AWG3.1 policy, rejects a tampered signature, uses the real profile
verifier/materializer, and connects through the actual service runtime and
vendor SCM tunnel. Admission uses a temporary fixture trust anchor in process.

The next phase registers a unique `VEX.CI.<GUID>` LocalSystem controller using
the unsigned acceptance executable. It runs the production named pipe server,
command handler, DPAPI authorization store, profile verifier, runtime and
background service. Its private pipe grants access only to the fixture owner,
administrators and LocalSystem. Fixture attestation checks the exact owned
probe/controller PID, image path, SHA256 and process owner SID. This dependency
is internal to the acceptance host; the production constructor retains its
fixed pipe and mandatory signed application attestation. The shared application
transport verifies a server before reading the authorization token and bounds
pipe connection separately from the longer VPN operation.

The drill rejects an invalid token, raw configuration and a tampered signed
profile over actual IPC, then exercises connect/status/diagnostics, controller
crash recovery, disconnect followed by restart, and graceful SCM shutdown
cleanup followed by another disconnected restart. A fifteen-second profile
uses the same ephemeral signing key to verify autonomous vendor/adapter/lease
cleanup before any post-expiry status request. It does not exercise the installed signed WinUI application,
Authenticode admission, the production keyring, or clicking the tray Exit item.
The peer defaults to 180 seconds and accepts at most 420 seconds for the longer
SCM drill; the wrapper also bounds the harness process and kills its owned peer
in `finally`. Portable tests start the actual CLI at 420 seconds, require its
ready manifest, terminate that exact child, and reject 421 seconds.

The Windows Wintun client owns `10.253.253.2/32` and only routes
`10.253.253.1/32`. The peer's `10.253.253.1` exists exclusively inside a Go
memory netstack, never on a host adapter. Its encrypted transport binds only to
an IPv4 address already assigned to the runner's physical default interface;
the peer rejects destinations not currently local to that host. This matches
the qualified vendor's physical-interface UDP binding without sending traffic
to another machine. A trusted in-process fixture option preserves the native
host route only after the service validates the address on an active physical
NIC; production defaults remain unchanged. After a fresh peer handshake, DNS UDP and HTTPS TCP sockets bind to
the actual Wintun source address and interface index. HTTPS verifies an
ephemeral root and the normal hostname, then checks a random response nonce.
Actual UAPI traffic counters must increase and peer DNS/HTTPS counters confirm
receipt. A same-host adapter delivery cannot satisfy this test.

Before tunnel creation, the production network controller creates one temporary
`192.0.2.253/32` documentation-address bypass through the physical gateway.
The harness refuses an existing route for that prefix on any interface, verifies
the actual metric and NetMgmt protocol against the confirmed ownership journal
and durable creation receipt, then rolls back and verifies absence. No packets
are sent to that address; failed or canceled checks still use independently
bounded, receipt-checked cleanup.

The wrapper refuses self-hosted runners, existing VPN services/adapters,
connected Windows VPN profiles, saved VEX service state, or occupied fixture
addresses/routes. Private keys stay in an ACL-restricted directory under
`RUNNER_TEMP`, outside artifacts. Deadlines bound every process; `finally`
stops and deletes only its verified fixture controller, stops its peer process,
uninstalls the previously absent vendor service
only when its image/config paths still point to this fixture, verifies adapter
and route cleanup, an unchanged native endpoint route, and unchanged physical DNS/firewall profiles, then deletes
fixture private material. Failed cleanup retains restricted ownership state
and fails the job; it never deletes arbitrary foreign state.

The preflight also requires an absent Wintun driver package and vendor data
directory. Cleanup calls the qualified DLL's `WintunDeleteDriver` API only after
the fixture adapter is gone and no Wintun adapter remains, then verifies that
the newly introduced package disappeared. It deletes only the known vendor
ringlogger file and empty directories that were absent before this run; any
unexpected file or redirected directory fails cleanup without recursive deletion.

Only the two sanitized result files (`.json` and `.json.cleanup.json`) belong
in artifacts. Never upload fixture manifests, keys, configs, raw UAPI, process
dumps or the temporary directory.

**Coverage:** The initial private `/32` phase disables AntiLeak. Ordinary
PR/main CI and explicit `-FullTunnelChecks` also exercise paired full IPv4 `/1`
routes, actual AntiLeak, tunnel DNS/HTTPS, the allowed physical VEX HTTPS control
route, and blocked/restored outside TCP and supported physical DNS. The same-host
peer has no public Internet forwarding. These checks do not qualify public VPN
egress, production authentication, installed signed UI-to-service attestation,
IPv6 traffic, Wi-Fi roaming, physical ARM64 or reboot. Those remain separate
Windows acceptance gates. The standalone [public egress verifier](../verify-public-vpn.ps1)
observes an already connected real Windows client against two public HTTPS
services; it does not connect the VPN or certify these other gates.

The peer's portable tests exercise the same encrypted DNS/TLS path between two
in-memory AWG endpoints without altering OS networking. Their default outer
endpoint is `127.0.0.1`; the Windows wrapper explicitly supplies its existing
physical host address. Both modes bind one specific local address and restrict
remote destinations to that selected, currently assigned host-local address:

```sh
cd native-windows/scripts/vpn-fixture-peer
go mod verify
go test -count=1 -timeout=60s ./...
```
