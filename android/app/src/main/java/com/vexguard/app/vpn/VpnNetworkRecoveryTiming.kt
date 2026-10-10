package com.vexguard.app.vpn

internal object VpnNetworkRecoveryTiming {
  const val CONNECT_HARD_RECOVERY_MS = 20_000L
  const val DISCONNECT_HARD_RECOVERY_MS = 8_000L
  const val BLOCKER_TRANSITION_TIMEOUT_MS = 2_000L
  const val DEBOUNCE_MS = 750L
  const val HANDSHAKE_ATTEMPTS = 60
  const val HANDSHAKE_POLL_MS = 250L

  // One supplied recovery candidate: native UP, three native DOWN calls, handshake,
  // and four blocker transitions, including failure cleanup. Preserve those
  // existing budgets rather than shortening normal handover recovery.
  // Native calls can outlive their control watchdogs: this bounds watchdog
  // deferral, not native execution time.
  const val MAX_PENDING_MS = CONNECT_HARD_RECOVERY_MS +
    3 * DISCONNECT_HARD_RECOVERY_MS + HANDSHAKE_ATTEMPTS * HANDSHAKE_POLL_MS +
    4 * BLOCKER_TRANSITION_TIMEOUT_MS + DEBOUNCE_MS
}
