# Account key recovery

Mobile account keys retain the confirmed active pair until the API acknowledges
the next pair. A pending rotation stores its private key, source device, base
public key and local owner before sending the rotation. Preparing a new intent
also records the confirmed source device in the existing account mapping.
The additional mapping field is optional; existing mappings remain readable.

When that source was deleted or revoked, recovery can use an existing replacement
only after checking its account, platform, managed client ownership, key and
epoch. A still-active original target keeps ownership of its pending intent.
An unrelated or newer public key cannot authorize a transfer. Missing or
malformed target IDs are rejected before challenge or registration dispatch.

The client requests a target-specific identity challenge with the exact purpose
`reconcile`. It then sends a signed `reconcile_device_id` through the existing
registration endpoint. This mode reads the current device and installation
binding together; it creates no device, metadata update, peer job or binding.
The API must confirm the same target, key and epoch with its verified binding.
An older API that returns `register`, an empty purpose or an unsupported response
is rejected before the reconciliation POST. A fresh challenge-specific request
key also prevents an older node from treating that POST as a creation replay
during a rolling API upgrade. Release the supporting API before
enabling this recovery through a client rollout.

The proven target is saved in the journal before updating the mapping pointer
or sending a rotation. A lost reconciliation response leaves the original
journal and active key intact. After a lost rotation reply, the same pending
private pair is reused. If the replacement already has that public key and an
accepted epoch, recovery promotes that pair without another rotation. Session
supersession and storage errors stop subsequent writes and dispatch.

Recovery does not automatically replay an uncertain registration or rotation.
It does not transfer an older orphan journal whose source cannot be confirmed
from the account mapping or its existing migration record. That case still
requires an explicit owner recovery flow. An omitted server base key after a
counter advance is also unfinished; neither case permits guessing key ownership.

Run `node --test tests/mobile-account-registration.test.cjs
tests/session-vpn-profile-owner-race.test.cjs` for account isolation, both mobile
platforms, durable write ordering, lost replies and owner/session guards.
`npm run check` includes these portable checks, type checking and lint. They do
not establish device tunnel acceptance or a production release.
