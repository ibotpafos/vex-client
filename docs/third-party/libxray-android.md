# Android Xray dependency

VEX uses a VEX rebuild of XTLS libXray for Android for the VLESS
backend. VLESS, XHTTP, TLS and the TUN TCP/IP implementation remain upstream
code; VEX does not implement those wire protocols.

- Release: `v26.11.9`, source commit
  `5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3`.
- Source: https://github.com/XTLS/libXray/tree/5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3
- Release: https://github.com/XTLS/libXray/releases/tag/v26.11.9
- VEX dependency archive: `libxray-android-v26.11.9-vex.1.zip`, 25,325,325 bytes;
  SHA-256 `a1b21cecdd76784dcf6b773eabeabb6f73c5b827164a32c36cab3f17eb18a500`.
- AAR SHA-256:
  `e23274cd660e0fda71d9ac53d14a0c297fb194b0a7b490f2cfef985fef31d680`.
- VEX rebuild dependency patch: https://github.com/ibotpafos/vex-client/releases/download/libxray-v26.11.9-vex.1/dependency-update.patch
  with SHA-256 `e31fd2ce5116a3c168a61439ef7260ea47443de0b5b1688c0a92f35f0929191e`.
  The rebuild uses `golang.org/x/crypto v0.59.0` and the upstream
  `github.com/klauspost/compress v1.20.3`.
- Generated source JAR SHA-256:
  `14641c3977eee0e7ce9c2e1bf2d3399c0158f11a1a500b4ba9b9d5d651c1a9dc`.
- Both shipping ARM ABIs (`arm64-v8a`, `armeabi-v7a`) are present. Their ELF
  load segments have 16,384-byte alignment; the bootstrap verifies these facts.
- `go version -m` on both ARM `libgojni.so` members reports `go1.27.4`,
  `GOOS=android`, and the expected `GOARCH=arm64` / `GOARCH=arm`. This meets
  the fixed compiler boundary for `GO-2026-6809`; changing the application's
  shell toolchain would not repair a vulnerable precompiled AAR. Advisory:
  https://pkg.go.dev/vuln/GO-2026-6809 .

`android/xray-android.lock.json` and `scripts/bootstrap_xray_android.py` pin and
verify the release. Gradle depends on that bounded bootstrap task. Downloaded
binaries stay in the local dependency cache and ignored `external/xray/` paths;
they are never committed. `libXray-sources.jar` is retained beside the AAR so
JNI signatures can be reviewed. This artifact exposes `libXray.LibXray.invoke`,
`registerDialerController`, `registerListenerController`, `setDNS`, `resetDNS`,
and `libXray.DialerController.protectFd(long)`.

libXray is MIT licensed; see `libXray-MIT.txt`. Its bundled Xray-core is MPL-2.0;
see `Xray-core-MPL-2.0.txt`. The pinned module declares the core dependency
`github.com/xtls/xray-core v1.260327.1-0.20261109052709-676eaf66f8f0`:
https://github.com/XTLS/Xray-core/tree/676eaf66f8f0 . Exact upstream source,
dependency manifests and associated notices are available from the pinned
libXray `go.mod` and `go.sum`. The two license texts and this provenance notice
are included in Android assets under `third_party/`.

The Xray runtime loads exclusively in the `:vless` process. MainApplication
returns before React Native, Expo, AWG or Sentry initialization in that process.
Every platform socket is protected and bound to a current physical underlay.
VEX-owned TUN capture remains open while a failed core is stopped/restarted.
The pinned core's Android TUN duplicates the supplied descriptor with
`F_DUPFD_CLOEXEC`; VEX lends an additional duplicate during synchronous startup
so upstream error cleanup cannot close its retained descriptor. See
https://github.com/XTLS/Xray-core/blob/676eaf66f8f0/proxy/tun/tun_android.go .
Whole-process death still requires Android's separately qualified lockdown
behavior; a retained file descriptor cannot survive the death of its owner.

The current VLESS surface is full tunnel with all or explicitly selected apps.
The VEX owner package stays outside capture so profile renewal remains possible
when protection blocks user traffic; an empty effective selection is rejected.
DNS A/AAAA queries are intercepted and resolved with DoH through VLESS; general
UDP is deliberately blocked to match the existing server contract. A native
authenticated loopback SOCKS inbound verifies owned HTTPS through the same
VLESS transport. Core startup alone, or a synthetic WireGuard timestamp, never
qualifies a VLESS connection as verified. TUN data-plane, handover and physical
device acceptance remain separate release checks.
