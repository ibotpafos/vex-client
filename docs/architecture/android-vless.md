# Android VLESS transport

The Android client retains AmneziaWG as the default transport and adds an
explicit VLESS choice. VLESS connects to the existing VEX XHTTP/TLS fleet;
it does not reinterpret those endpoints as Reality, WebSocket or HTTPUpgrade.
The first implementation uses a full tunnel and the existing per-app selection.
The AmneziaWG smart-routing preference is retained for switching back.

## Engine and process boundary

Use the official [XTLS/libXray](https://github.com/XTLS/libXray) Android library,
pinned to `v26.10.31` / source `7fe8528063e54343af8ba9a37431afc56000de21`.
The upstream Android ZIP is pinned by SHA-256
`fb99f04acf379cc2957c1e1d0ce2b3c0005d3f49974a44c09a11242a0562c1ca`.
The wrapper is MIT licensed and Xray-core is MPL-2.0; retain upstream notices.
The official Xray TUN inbound consumes an Android VPN file descriptor.

libXray and the existing AWG backend embed independently built Go runtimes.
They must run in different OS processes. The VLESS VPN service runs in
`:vless`; that process skips React Native and AWG initialization. The main app
uses private Binder IPC and never loads libXray. The service protects its own
upstream sockets and binds them to a non-VPN underlay to prevent routing loops.

An engine start is not evidence of connectivity. VLESS reports a fresh
connection ID and verification time only after an owned HTTPS request through
the VLESS path succeeds. It does not synthesize a WireGuard handshake.
Network changes invalidate that proof before recovery. Retain the TUN and
block traffic when an in-process engine failure occurs with anti-leak enabled.
OS process-death/lockdown behavior requires separate device acceptance.

## Server contract

The existing native registration and device ID remain authoritative. Do not
create another paid device, export client-owned WireGuard keys, or impersonate
INCY through User-Agent headers. A new authenticated facade uses the existing
managed TCP credentials, access checks, route admission and accounting.

`POST /v1/vpn/vless-profile`, with session authorization and
`X-Vex-Platform: android`:

```json
{
  "device_id": "<owned native Android device>",
  "location_id": "<selected location>",
  "transport_capability": "vless-xhttp-v1"
}
```

The response contains `schema_version: 1`, `protocol: "vless"`, the same
`device_id` and `location_id`, a stable admitted `route_id`, `expires_at`, and
`config` as an Xray JSON string. Both client and server validate the device,
location and protocol binding. Unsupported servers fail explicitly; the client
does not silently change a user-selected VLESS connection into AmneziaWG.

The endpoint must preserve owner/session/device, entitlement, quota, rollout,
revocation and qualified-route checks. Existing INCY exports must continue to
reject client-owned AWG devices. TCP-specific enrollment must not weaken that
guard. Neither credentials nor full connection configurations belong in logs,
diagnostic samples, commits or public release descriptions.

## Compatibility and acceptance

Old native binaries lack `connectVless`; they keep the AmneziaWG UI/path.
Existing profiles without a discriminator remain AmneziaWG. Cache keys and
operation ownership distinguish transports. VLESS health and renewal must not
depend on WireGuard handshakes or rotate WireGuard keys.

The existing TCP fleet blocks arbitrary UDP payloads. DNS must use the reviewed
TCP/HTTPS path inside VLESS, with no direct resolver fallback. Full-tunnel and
per-app data-plane checks must be exercised on a physical device alongside
connect/disconnect, protocol switching, interruption and leak protection.

The release gate includes Wi-Fi to cellular and cellular to Wi-Fi. On
4 November 2026 the attached Mi A1 detected its SIM but had no cellular service;
the owner confirmed that mobile internet was unavailable. That matrix remains
unqualified. A successful build or Wi-Fi-only test cannot satisfy it.

The current release workflow rebuilds the tagged source after signing a
pre-release candidate. Source equality alone does not prove the final APK is
byte-identical to a device-accepted candidate. Preserve exact artifact provenance
and qualify the delivered APK before claiming final binary acceptance.
