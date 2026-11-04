# Android Xray dependency

VEX uses the unmodified official XTLS libXray Android artifact for the VLESS
backend. VLESS, XHTTP, TLS and the TUN TCP/IP implementation remain upstream
code; VEX does not implement those wire protocols.

- Release: `v26.10.31`, source commit
  `7fe8528063e54343af8ba9a37431afc56000de21`.
- Source: https://github.com/XTLS/libXray/tree/7fe8528063e54343af8ba9a37431afc56000de21
- Release: https://github.com/XTLS/libXray/releases/tag/v26.10.31
- Archive: `libxray-android.zip`, 52,277,046 bytes;
  SHA-256 `fb99f04acf379cc2957c1e1d0ce2b3c0005d3f49974a44c09a11242a0562c1ca`.
- AAR SHA-256:
  `4c90532f61ff8363e7fcf52e064ff1aa66d065e06afbadc0ea4c6acf384c452f`.
- Generated source JAR SHA-256:
  `14641c3977eee0e7ce9c2e1bf2d3399c0158f11a1a500b4ba9b9d5d651c1a9dc`.
- Both shipping ARM ABIs (`arm64-v8a`, `armeabi-v7a`) are present. Their ELF
  load segments have 16,384-byte alignment; the bootstrap verifies these facts.

`android/xray-android.lock.json` and `scripts/bootstrap_xray_android.py` pin and
verify the release. Gradle depends on that bounded bootstrap task. Downloaded
binaries stay in the local dependency cache and ignored `external/xray/` paths;
they are never committed. `libXray-sources.jar` is retained beside the AAR so
JNI signatures can be reviewed. This artifact exposes `libXray.LibXray.invoke`,
`registerDialerController`, `registerListenerController`, `setDNS`, `resetDNS`,
and `libXray.DialerController.protectFd(long)`.

libXray is MIT licensed; see `libXray-MIT.txt`. Its bundled Xray-core is MPL-2.0;
see `Xray-core-MPL-2.0.txt`. The pinned module declares the core dependency
`github.com/xtls/xray-core v1.260327.1-0.20261031132019-a4a3dff5b20c`:
https://github.com/XTLS/Xray-core/tree/a4a3dff5b20c . Exact upstream source,
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
https://github.com/XTLS/Xray-core/blob/a4a3dff5b20c/proxy/tun/tun_android.go .
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
