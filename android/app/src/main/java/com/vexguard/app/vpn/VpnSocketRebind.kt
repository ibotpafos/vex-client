package com.vexguard.app.vpn

import java.util.concurrent.CancellationException

/** Retry transient socket binding failures while keeping the existing TUN installed. */
object VpnSocketRebind {
  enum class Result { REBOUND, SUPERSEDED, FAILED }

  suspend fun recover(
    isCurrentNetwork: () -> Boolean,
    bindSockets: () -> Unit,
    waitBeforeRetry: suspend (Long) -> Unit,
    onFailure: (Exception) -> Unit,
  ): Result {
    repeat(3) { attempt ->
      if (!isCurrentNetwork()) return Result.SUPERSEDED
      try {
        bindSockets()
        return if (isCurrentNetwork()) Result.REBOUND else Result.SUPERSEDED
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        onFailure(error)
      }
      if (attempt < 2) waitBeforeRetry(250L shl attempt)
    }
    return if (isCurrentNetwork()) Result.FAILED else Result.SUPERSEDED
  }
}
