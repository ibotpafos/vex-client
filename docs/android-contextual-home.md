# Android contextual Home notices

Candidate: Android 1.0.67, build 75 (versionCode 1006775). Not a published release.

Home keeps the connection control and server choice primary:
- Show finite, valid traffic quota only at <=10% remaining or a confirmed reached limit.
  Missing, unlimited or invalid measurements do not invent a low-traffic warning.
  Full quota/reset/multiplier details remain in Settings.
- Show access action only when VPN access is inactive or known expiry is within 24 hours,
  including trials. A stale expired snapshot with access still enabled remains hidden.
  Renewal and support stay available in Settings; no billing/access data is changed.
- Keep a neutral updates icon next to Settings. Attention badges cover optional APK
  and pending OTA; mandatory native recovery stays prominent.
- Open the existing update center from the icon. Reuse one Expo update controller
  for checks/fetch/retry/apply; do not add another fetch or a polling service.
- A downloaded OTA no longer covers Home indefinitely. Progress/error and actual
  apply/rollback outcomes remain observable. Native VPN, traffic-blocker and foreground
  guards remain authoritative; concurrent reload attempts share one lock.

Verification: full unit suite, typecheck, lint, client CI/release and upstream contracts
pass locally. Executable fixtures cover exact thresholds, invalid data, API-metadata-free
ready state, Later/retry, active VPN, concurrent reload and foreground/background race.
Source rollback reconstructs the exact native archive and restores the pristine hash.

Device/release acceptance is recorded outside Git. Never infer candidate67 acceptance
from previously accepted candidate66 screenshots. Production needs a new exact signed
APK/device/preview result and immutable Android-only release tag plus website receipt.
