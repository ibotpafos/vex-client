# Profile identity numbers

Mobile profile versions and account-scoped key epochs use exact JavaScript
integers. A supplied profile version must be positive and no greater than
`Number.MAX_SAFE_INTEGER`; device epochs may also be zero for legacy records.
An omitted legacy device epoch remains omitted. Explicit null, strings,
fractions, negative, nonfinite and unsafe epoch values are rejected.

An epoch supplied for rotation is validated before account setup or native key
generation. Server authority determines the next epoch, preserving `(8, 5) → 6`.
Missing local/server epochs still start at one; server epoch zero advances to
one. An unrepresentable next epoch fails before a rotation POST or key write.

Cached hints, request coalescing and outbound `known_version` share the positive
safe-integer rule. A malformed hint cannot authorize cached configuration.
Explicit malformed response versions fail after the first profile GET, without
another device lookup or profile assignment. A provided unchanged-response
version must equal the validated cached version. Legacy responses may omit
their version; staged responses require valid matching outer/nested versions.
Revocation and authorization errors retain their precedence.

Versions are identity tokens, not universally monotonic counters. The client
does not require increases or impose a rendered-profile hash maximum on staged
versions. Push parsing accepts complete decimal strings, including surrounding
whitespace and leading zeros, then checks the exact numeric range. Prefixes,
fractions, exponents, signs and coercible objects cannot select a stage.

Android push admission applies the same decimal/range rule using `Long`, while
keeping the original string event format and queue storage. Versions above
32-bit range can therefore reach the JavaScript parser without truncation.

The legacy Android global key bridge and preference store retain their existing
positive 32-bit range. They reject unrepresentable/fractional inputs before
conversion or replacement, and generation checks overflow before creating a
key. Account-scoped JSON keys remain a separate safe-integer contract. No
preference schema migration or wide-epoch support for that legacy bridge is
claimed. Existing native formats, session ownership, ACK ordering and PSK
activation policy remain in place.

Account creation requests counter-independent key material. Rotation/recovery
use it when the authoritative server epoch is available; a legacy omitted
epoch retains generation's existing next-epoch hint. Updated Android/iOS
bridges expose an optional zero-argument method
that generates a candidate with epoch one without reading or advancing the
global counter. The account transaction still chooses its authoritative epoch.
Default legacy generation remains checked and unchanged within its range.
Older binaries retain the existing generator when that optional method is
absent; a failure from the new method is propagated without another generation.

The iOS addition follows the existing zero-argument `AsyncFunction` convention
checked against the installed Expo SDK57 argument validator and the official
[SDK57 reference](https://docs.expo.dev/versions/v57.0.0/) and
[module API](https://docs.expo.dev/modules/module-api/).
