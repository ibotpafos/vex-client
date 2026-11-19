# Pinned AWG network adapter

Source: amnezia-vpn/amneziawg-go/v3 v3.1.20260828, tun/netstack/tun.go.
Upstream SHA256: `a5c29a6d68b63012d012a2c978fbfff9e144407fb0a75215593f77781802fe82`.
The MIT header and license are preserved. Local changes serialize shutdown with
in-flight WriteNotify callbacks and cancel blocked sends before closing the
packet channel. The AWG cryptographic core and module versions are unchanged.

The numeric dial port is narrowed immediately after the existing explicit
0..65535 bounds check and stored as uint16, including the zero default for ping.
This makes the checked conversion local to its parsing branch for static
analysis. Atoi's accepted numeric forms and existing errors are retained;
literal-address/cancelled-context regressions verify both sides of the bounds.

The original file also matches Android upstream pin
`b5928efb6ca19f0153958460c3d141f04abc5c2e` (Git blob
`39821b93bd2805bcad9e3c42ea5ccd6a6f780312`).
