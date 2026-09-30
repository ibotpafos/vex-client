# Android 1.0.60 candidate — not published

Candidate: Android version 1.0.60, internal build 68, versionCode 1006068,
OTA runtime 1.0.60. iOS and frozen native Windows metadata are unchanged.

Published baseline remains Android 1.0.59, versionCode 1005967. The earlier
signed 1.0.59/68 artifact is not the 1.0.60 artifact and must not be renamed.

The release PR must stay draft: the candidate `versions.json` checksum and
signature URL are deliberately empty until a new production-signed artifact
is built and verified. The existing release-metadata test rejects this state;
do not relax that test or merge/deploy empty candidate metadata.

TODO: Populate checksum/signature URL from the verified 1.0.60 signed artifact,
rerun the full client check, compare signer/package/ABI/minSdk/versionCode to
the published baseline, and prove device installation and signed preview OTA
apply/connected-VPN deferral/rollback before promoting the customer release.
The Android device is currently absent from adb; broader Android and network
transition acceptance also remains open.
