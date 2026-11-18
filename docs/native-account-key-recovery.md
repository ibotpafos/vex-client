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

Cancelling a profile request also stops its pending-key recovery at the existing
account-owner fences. A cancellation during journal persistence cannot start a
later rotation, including implicit repair after a rejected local key sync;
a cancellation after an identity challenge cannot dispatch its
proof. If cancellation arrives while the active key is being saved, the pending
journal stays available for the next reconciliation. Already accepted requests
may complete; cancellation does not prove that the server rejected a mutation.

Shared registration remains a session-owned transaction. Cancelling one profile
borrower does not interrupt its durable confirmation or another live borrower.
Profile-owned recovery combines the request cancellation and session checks
without applying that request lifetime to the shared registration.

When the device list omits its public key after an epoch advance, recovery uses
the same noncreating proof. It first confirms the pending public key, because a
lost rotation reply may already have committed it. Only the specific
`409 conflict / device_rebind_required` response permits checking the recorded
base key (or the existing local key when no base was recorded). Other errors,
unsupported proof and malformed acknowledgements retain the journal and stop.
A confirmed base rebases the existing intent to the next device epoch; it never
generates another private pair. The acknowledgement must match the requested
device, public key and exact epoch.

After a successful key acknowledgement, the active V1 key blob atomically stores
an optional `confirmedKeyDeviceId` alongside the existing key triple. Existing
V1 blobs remain readable, and the preceding V1 reader ignores this extra field.
An unconfirmed key save clears the receipt. Storage failure preserves the
previous blob. The registration mapping's source pointer is separate: saving
that pointer alone does not prove that a key was applied.

For later uncached preparations, concurrent borrowers and restarts, an omitted
list key with a receipt requires a fresh signed noncreating proof, even when the
epoch is unchanged. Its failure cannot fall back to sync or rotation. A lower
epoch on the same device is rejected before proof or persistence; another
confirmed device has its own epoch sequence. Native profile admission checks
the receipt's device ID, preventing a cached profile for the preceding target
from reaching the native callback after replacement.

Registration and recovery disable automatic transport retries. A later
preparation may recover and resend an existing durable rotation intent using
the same private pair; a lost response may already have committed that intent.
It does not transfer an older orphan journal whose source cannot be confirmed
from the account mapping or its existing migration record. That case still
requires an explicit owner recovery flow. Uncertain profile issuance and later
watchdog outcomes remain separate work. The omitted-base recovery above needs
the supporting noncreating API capability before client rollout; unavailable
proof stops safely without creating another device or key.

The current portable account suite passes 256 tests on the iOS/Android fixtures.
The exact preceding source passes 189 and fails 67 of these assertions; six
additional receipt-guard cases reproduce against the intermediate implementation.
Full `npm run check` passes with 1082 standard Node PASS events, one existing
installed-Expo Swift-validator skip, 48 Python tests, types, lint and portable
CI/release checks. Counts overlap; skipped/device/runtime paths remain unaccepted.

Run `node --test tests/mobile-account-registration.test.cjs
tests/session-vpn-profile-owner-race.test.cjs` for account isolation, both mobile
platforms, durable write ordering, lost replies and owner/session guards.
`npm run check` includes these portable checks, type checking and lint. They do
not establish device tunnel acceptance or a production release.
