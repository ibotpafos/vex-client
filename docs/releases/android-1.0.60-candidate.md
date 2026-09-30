# Android 1.0.60 candidate — not published

Candidate: Android version 1.0.60, internal build 68, versionCode 1006068,
OTA runtime 1.0.60. iOS and frozen native Windows metadata are unchanged.

Published baseline remains Android 1.0.59, versionCode 1005967. The earlier
signed 1.0.59/68 artifact is not the 1.0.60 artifact and must not be renamed.

The release PR must stay draft until the remaining device/OTA/customer gates
pass. Signing run 36707722877 built updated-dependency source commit 2231c17;
APK SHA-256 is b3f8fcd5f947d9dec3a8bf84627912b8cfbf06a23410fcfb267ead9f1f25fdaa.
The sidecar, production signer, package, both ABIs and published-baseline upgrade
compatibility passed. `versions.json` is now bound to that verified checksum
and the candidate signature URL; this does not publish the download URL.

TODO: Prove device installation and signed preview OTA
apply/connected-VPN deferral/rollback before promoting the customer release.
The Android 9 device is connected and charging, but these acceptance gates
have not yet passed; broader Android and network transition acceptance also
remains open.
