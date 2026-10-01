package com.vexguard.app.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

internal suspend fun pollVpnStatus(
  shouldContinue: () -> Boolean,
  poll: suspend () -> Long,
  onError: (Throwable) -> Unit,
  errorDelayMs: Long,
) {
  while (currentCoroutineContext().isActive && shouldContinue()) {
    try {
      delay(poll())
    } catch (cancelled: CancellationException) {
      // Listener teardown and module invalidation are normal coroutine cancellation.
      throw cancelled
    } catch (error: Throwable) {
      onError(error)
      delay(errorDelayMs)
    }
  }
}
