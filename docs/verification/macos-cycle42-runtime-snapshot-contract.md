# C42 — real Runtime snapshot/cutover contract, offline only

## Provenance correction

The C41 next-action/TODO confused two layers. `SystemTunnelController.protectedReplacementSnapshot`
returns five fields internally when healthy. `HelperRuntime` handles the public
`protected-snapshot` command by generating and retaining a short-lived, one-use
`ProtectedGrant`, and appending a canonical `transaction_id`. The actual public
healthy reply therefore has **six fields**. `protected-replace` requires and
consumes that root grant. A client-generated replacement nonce is rejected.

The C42 evaluator compiles the actual Runtime, controller, command parser,
journal/receipt/pre-stage stores, native coordinator and descriptor-owned app
persistence together. It proves both layers directly, rather than substituting
an internal five-field reply for the public transport. Initial signed App PSK
cutover also executes through the actual Runtime and helper wrapper with
pre-stage opt-in both disabled and enabled. It already works in C42 BASELINE;
there was no missing-public-nonce bug. Historical C41 records are retained with
this correction, not rewritten or silently treated as installed-helper proof.

## Fix

`NativeProtectedReplacementCoordinator.replace` now rejects unknown fields,
noncanonical spacing, embedded newlines/tabs/CR, and unsupported receipt versions
before writing the private intent, staging config or calling authorization.
Keep the exact canonical current six-field wire contract and older five-field
**with transaction ID / without receipt support** compatibility. The internal
five-field **without transaction ID** response never authorizes a replacement.

No new client nonce allocator, root protocol changes, nonce reconstruction,
TTL extension, generic reconnect, owner adoption, key creation, DNS resolution,
Root grant bypass or default pre-stage opt-in was introduced. Existing owned
canonical persistence/CAS, original process/scope/generation and exact retry
are reused. The root still reauthenticates peer/owner/source/candidate and
consumes the grant before physical work.

## Checks

- `test_macos_runtime_snapshot_contract.py ROOT`: 55 checks; actual Runtime
  nonce/initial cutover, malformed wire denied before private/config/root writes,
  stale operation, lost stage/private ACK exact retry, original expiry,
  consumed/invented nonce denial, owned CAS race, older field format and retained
  old-process/foreign-scope/corrupt/unsafe-mode nonce fences.
- Same evaluator with `ROOT app`: two actual signed App/helper/Runtime cutovers,
  default vs explicit pre-stage consent, config staging after nonce custody,
  armed fake firewall, root commit, optional fresh receipt proof, admission/cache
  and exact private retirement. The default intentionally has no extra receipt
  RPC; the opt-in path requires one, as the actual App code specifies.
- Existing C41 legacy retirement/admission, pre-stage/cancellation/owner,
  journal/receipt/PSK/ordinary/pending regression gates remain in the aggregate.
- Identical frozen evaluator inputs for BASELINE/MODIFIED/ROLLBACK; source and
  package results, literal output/status, hashes and copy rollbacks are recorded
  in the permanent transaction roles. Interim fixture outcomes are not final
  acceptance. No expected denial is counted as successful installed operation.

All root command/firewall/file/process/peer ports are inert fixtures; only bounded
private app files are written under owned disposable temporary directories.
No installed app/helper, AF_UNIX transport, kernel/current-console-UID trust,
OS crash/power-loss, real network/leak or update/install/release acceptance is
claimed. Developer ID/notarization/provisioning and an isolated test Mac remain
required for public release. Full Android parity/release objective stays active.
