package com.vexguard.app.vpn

import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class VpnSocketRebindTest {
  @Test
  fun transientFailureRecoversWithoutAnotherNetworkCallback() = runBlocking {
    var attempts = 0
    var failures = 0
    val waits = mutableListOf<Long>()
    val result = VpnSocketRebind.recover(
      isCurrentNetwork = { true },
      bindSockets = { if (++attempts == 1) throw IllegalStateException("transient bind failure") },
      waitBeforeRetry = { waits.add(it) },
      onFailure = { failures++ },
    )
    assertEquals(VpnSocketRebind.Result.REBOUND, result)
    assertEquals(2, attempts)
    assertEquals(1, failures)
    assertEquals(listOf(250L), waits)
  }

  @Test
  fun persistentFailureStopsAfterBoundedRetries() = runBlocking {
    var attempts = 0
    val waits = mutableListOf<Long>()
    val result = VpnSocketRebind.recover(
      isCurrentNetwork = { true },
      bindSockets = { attempts++; throw IllegalStateException("bind unavailable") },
      waitBeforeRetry = { waits.add(it) },
      onFailure = {},
    )
    assertEquals(VpnSocketRebind.Result.FAILED, result)
    assertEquals(3, attempts)
    assertEquals(listOf(250L, 500L), waits)
  }

  @Test
  fun supersededNetworkIsNeverRebound() = runBlocking {
    val result = VpnSocketRebind.recover(
      isCurrentNetwork = { false },
      bindSockets = { error("superseded network must not be rebound") },
      waitBeforeRetry = { error("superseded recovery must not wait") },
      onFailure = { error("unexpected bind") },
    )
    assertEquals(VpnSocketRebind.Result.SUPERSEDED, result)
  }

  @Test
  fun networkChangeDuringBackoffCancelsFurtherBindings() = runBlocking {
    var current = true
    var attempts = 0
    val result = VpnSocketRebind.recover(
      isCurrentNetwork = { current },
      bindSockets = { attempts++; throw IllegalStateException("bind unavailable") },
      waitBeforeRetry = { current = false },
      onFailure = {},
    )
    assertEquals(VpnSocketRebind.Result.SUPERSEDED, result)
    assertEquals(1, attempts)
  }

  @Test
  fun cancellationDoesNotBecomeARebuildRequest() {
    assertThrows(CancellationException::class.java) {
      runBlocking {
        VpnSocketRebind.recover(
          isCurrentNetwork = { true },
          bindSockets = { throw CancellationException("cancelled") },
          waitBeforeRetry = { error("cancelled recovery must not wait") },
          onFailure = { error("cancellation must propagate") },
        )
      }
    }
  }
}
