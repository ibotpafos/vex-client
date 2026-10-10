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
vendor SCM tunnel. Admission uses a temporary fixture trust anchor in process;
this is not a production keyring or IPC client attestation test.

The Windows Wintun client owns `10.253.253.2/32` and only routes
`10.253.253.1/32`. The peer's `10.253.253.1` exists exclusively inside a Go
memory netstack, never on a host adapter. Its encrypted transport is bound to
`127.0.0.1`. After a fresh peer handshake, DNS UDP and HTTPS TCP sockets bind to
the actual Wintun source address and interface index. HTTPS verifies an
ephemeral root and the normal hostname, then checks a random response nonce.
Actual UAPI traffic counters must increase and peer DNS/HTTPS counters confirm
receipt. A same-host adapter delivery cannot satisfy this test.

The wrapper refuses self-hosted runners, existing VPN services/adapters,
connected Windows VPN profiles, saved VEX service state, or occupied fixture
addresses/routes. Private keys stay in an ACL-restricted directory under
`RUNNER_TEMP`, outside artifacts. Deadlines bound every process; `finally`
stops only its peer process, uninstalls the previously absent vendor service
only when its image/config paths still point to this fixture, verifies adapter
and route cleanup and unchanged physical DNS/firewall profiles, then deletes
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

**Coverage limits:** AntiLeak is explicitly disabled to preserve the CI control
channel. This proves real local encrypted traffic and lifecycle on Windows x64;
it does not prove public Internet reachability, full/split route catalogs,
IPv6 traffic, Wi-Fi roaming, leak protection, arm64 runtime behavior or a signed
release. Those still require their own Windows acceptance gates.

The peer's portable tests exercise the same encrypted DNS/TLS path between two
in-memory AWG endpoints without altering OS networking:

```sh
cd native-windows/scripts/vpn-fixture-peer
go mod verify
go test -count=1 -timeout=60s ./...
```
