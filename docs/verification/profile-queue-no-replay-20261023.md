# Shared profile issuance failure

Parent: `1e1e1617966ea22177525cb6f864f66b3a39d588`.

A foreground profile request can borrow an in-flight background request with
the same token, location, routing and revalidation identity. Previously, every
failure requeued each foreground callback. The actual profile producer could
therefore issue a second profile GET after a lost/503/malformed first response,
even though the HTTP transport itself was configured for one attempt.

The existing queue now marks callback entry and shares a started callback's
error with live/current borrowers. Cancellation and stale-session outcomes keep
their existing owners. Only queue refusal before callback entry permits a new
foreground owner. Multiple borrowers remain coalesced under that one owner;
foreground priority over queued background work is preserved. A separately
requested operation still runs after the slot is released.

Six regression controls use the actual resolveVpnProfile/preparedTunnel/client/
queue functions with fake HTTP/platform boundaries. Network loss,503 and invalid
JSON each produced two profile GETs on the parent, with or without leader
cancellation. The fixed cases require one dispatch, shared error identity,
cancellation isolation, no config/key fallback and no retained timers.

Three boundary cases cover safe pre-callback refusal with multiple borrowers,
a misleading superseded error thrown after callback entry, and stale/live
followers alongside separate queued intent. An intermediate implementation
requeued multiple borrowers separately; its control reproduced the duplicate
before consolidation under one owner. The cancellation suite passes165 cases.
The existing queue compatibility script and complete portable check pass.

Tests use inert adapters and fake endpoints. They do not connect a VPN, mutate
routes/DNS/PF, exercise physical devices or establish Windows tunnel acceptance.
Wire/key/storage formats, HTTP producers and native platform backends are
unchanged. The remaining higher-level reconnect, key and candidate paths still
need their own source-bound qualification. See [replay contract](../profile-request-replay.md).


The read-only review also identified a separate pre-existing Swift caller path:
fresh-profile resolution and native connect lived inside one recovery catch.
The existing VpnAdmissionRecovery helper now receives resolve/connect separately
and awaits resolve before that catch. VEXAppState uses these explicit phases.
Network/HTTP/decode/cancellation during resolution propagates without native or
location failover. Successful native transport recovery, invalid configuration
and unconfirmed teardown behavior retain their original checks.

An executable control against the parent helper records two issuance callbacks
for network/HTTP/decode resolution failures. The fixed shared recovery harness
checks one resolution and zero native/failover calls for four error classes,
alongside the three preceding admission/transport/disconnect cases and success.
This is scoped orchestration evidence with fake dependencies; physical tunnel
acceptance and the remaining recovery matrix remain separate.


Local SwiftPM build succeeds for both executable products, VEXNativeMac and
VEXPrivilegedHelper. The local filtered XCTest attempt is unavailable because
the selected Command Line Tools installation has no XCTest module. The shared
standalone harness passes the same eight scenarios. The existing macOS CI
swift-test job must compile and execute the XCTest wrapper; local CLI success
does not replace that check. No executable/helper or VPN was started by the build.
