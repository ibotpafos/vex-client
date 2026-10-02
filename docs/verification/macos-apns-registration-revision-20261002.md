# macOS APNs registration revision — offline candidate

Baseline: native ceecefb752f5, backend 8ca9628c4fdb. Initial actual in-process gate exited 1: token-only DELETE returned 200 and cleared a newer same-token registration. Not a live production finding.

POST keeps legacy APNs/FCM request bodies; response adds positive persisted registration_revision. Every token update advances the server counter, including same-token registration. Native SDK accepts only positive Int64 receipts. DELETE requires exact owner/device/provider/token/revision and never falls back to token-only removal. The DELETE endpoint was added only to this isolated unreleased candidate; it has not been deployed.

Actual compiled native URLProtocol and shared-server two-service fakes cover invalid receipts, exact JSON, stale receipt preserving newer same-token registration, newest receipt cleanup, and no cleanup without a receipt. These are offline model/API contract proofs, not live DB/APNs or launched-app acceptance.

A revision-bound DELETE does not order arbitrary late POSTs after a transport timeout. Durable operation IDs/session intent and server reconciliation remain unfinished; TODO markers are retained at the actual native transport path. No background cleanup retry, manufactured revision or wildcard deletion is permitted.

Full goal remains Android parity and release readiness. Developer ID, notarization, current production public-key match, APNs provisioning/delivery, domain/per-app enforcement and isolated signed install/connect/update/leak tests are not established by this cycle. Active INCY VPN, route/DNS/PF state, original source checkout and original helper bytes are protected.
