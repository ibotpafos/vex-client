package com.vexguard.app.vpn

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class VpnNetworkRecoveryWindow(
  private val maxDurationMs: Long,
  private val nowMs: () -> Long,
  private val onExpired: () -> Unit = {},
) {
  private var generation = 0L
  private var startedAtMs: Long? = null

  @Synchronized
  fun begin(): Long {
    startedAtMs = nowMs()
    return ++generation
  }

  @Synchronized
  fun finish(token: Long) {
    if (token == generation) startedAtMs = null
  }

  @Synchronized
  fun isPending(): Boolean {
    val started = startedAtMs ?: return false
    if (nowMs() - started < maxDurationMs) return true
    // Release only this watchdog guard. The existing recovery still owns its
    // mutex and fail-closed tunnel/blocker; its normal cleanup is unchanged.
    startedAtMs = null
    onExpired()
    return false
  }
}

internal suspend fun <T> runVpnNetworkRecovery(
  mutex: Mutex,
  window: VpnNetworkRecoveryWindow,
  debounceMs: Long,
  operation: suspend () -> T,
): T {
  delay(debounceMs)
  return mutex.withLock {
    // A queued recovery cannot make progress while a control operation owns
    // the mutex, so it must not hide that operation from its watchdog.
    val token = window.begin()
    try {
      operation()
    } finally {
      window.finish(token)
    }
  }
}
