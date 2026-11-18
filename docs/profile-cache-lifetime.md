# Mobile profile cache lifetime

An authoritative profile resolution starts a local cache receipt. Memory,
query/active copies and persistent hot profiles share the existing inclusive
24-hour lifetime: exactly 24 hours is usable; one millisecond later requires
online resolution. Invalid, negative or backward clocks cannot validate an
existing receipt. Reaching this limit does not disconnect an established tunnel.

`VpnProfile.cacheSavedAtMs` carries the receipt between runtime copies. A hot
record's outer `savedAtMs` is authoritative on hydration, even if a nested field
disagrees. Saving a local copy retains that original timestamp and strips its
duplicate nested field. Expired or malformed receipts cannot replace a fresh
record. Cache hits, endpoint success and repeated persistence never renew it.

Successful online resolution, including a server-confirmed unchanged profile,
starts a new receipt. Validated staged configuration also starts a new receipt;
automatic PSK activation policy is unchanged. A profile merely labelled `api`
does not renew an existing receipt when saved.

Legacy runtime profiles without the optional metadata remain accepted. The
local eligibility path returns an anchored copy, and the owning hook replaces
its query entry with that copy. Repeated external submission of an original
metadata-free object is outside this receipt guarantee. Persistent records
always require their existing outer timestamp; explicit null, malformed or
nonfinite metadata never receives the legacy exception.

Both query and hot paths recheck eligibility after awaiting VPN permission.
If the selected copy expires meanwhile, resolution continues online and reuses
the permission already granted for that preparation. Existing location,
routing, address, session ownership, entitlement and server-authority checks
remain in place. Runtime key generation is shared without changing key bytes.

The storage key, schema version, API DTOs and published native formats retain
their existing contracts. This policy is a local freshness limit, not proof of
current entitlement, key validity, device acceptance or a successful tunnel.
