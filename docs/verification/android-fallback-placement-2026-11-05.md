# Android fallback placement acceptance

Candidate: Android 1.0.90, build 98, version code 1009098. Publication remains conditional on physical Wi-Fi and VLESS acceptance.

## Reproduced failure

Issuing a fresh profile for one location can move the shared installation's server peer. If that transport fails, the connect flow previously activated the next location's cached profile. Its retained peer could still handshake briefly while the canonical server placement remained at the failed location. Subsequent cleanup could then interrupt an apparently connected tunnel.

The real 1.0.89 device tests observed selected-app HTTPS and fresh DNS failures while a bypass app remained online. A second HTTPS origin, including normal TLS directly to its public IP, reproduced the failure. Server audit records correlate the attempted location change with the failed connection path, and a foreground profile refresh restored the previous placement. These observations support the regression scenario; they do not establish every packet-loss cause. A later stable phase passed 45 of 45 ordinary-UID HTTPS and fresh-DNS probes without resuming VEX. The failed phases remain failures.

## Change and local checks

Cross-location fallback now requests a fresh profile before native activation, with cached preference disabled and Android permission acquisition prohibited. The initial cached fast path, same-location recovery, handshake freshness, deadlines, ownership fences, application selection and anti-leak policy remain intact. A rejected placement refresh cannot activate the cached fallback.

The tests execute the actual production connection callbacks with inert native/API adapters and a shared server-placement model. Before the fix, the placement-consistency and rejected-refresh cases failed; the initial cached fast-path case passed. After the fix, all three pass. The existing session and verification suite passes 112 cases.

## Remaining physical gate

Verify the signed candidate source, tag, APK, mapping, version and signer before replacement installation. Repeat the automatic cross-location fallback with ordinary included/bypass UIDs, then the full VLESS Wi-Fi matrix: stable HTTPS/DNS, short and 45-second outages while VEX is backgrounded, protocol switches, per-app routing, explicit stop and no automatic reconnect. Restore the owner's original preferences.

The production VLESS profile API must be accepted first. A restored older API or a successful APK build does not satisfy that contract. Neither candidate 1.0.89 nor 1.0.90 is announced as released by this record.
