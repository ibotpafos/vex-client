package com.vexguard.app.vpn

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.yield
import org.amnezia.awg.backend.Tunnel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnNativeTunnelLossTest {
  @Test
  fun protectsUnexpectedDownWithRetainedArmedConnection() {
    assertTrue(shouldProtectAfterNativeTunnelLoss(true, true, false, Tunnel.State.DOWN))
  }

  @Test
  fun startupAndReleasedConnectionsDoNotBlock() {
    assertFalse(shouldProtectAfterNativeTunnelLoss(false, false, false, Tunnel.State.DOWN))
    assertFalse(shouldProtectAfterNativeTunnelLoss(false, true, false, Tunnel.State.DOWN))
    assertFalse(shouldProtectAfterNativeTunnelLoss(true, false, false, Tunnel.State.DOWN))
  }

  @Test
  fun rejectsStaleDownAfterSuccessfulHandover() {
    assertFalse(shouldProtectAfterNativeTunnelLoss(true, true, false, Tunnel.State.UP))
    assertFalse(shouldProtectAfterNativeTunnelLoss(true, true, false, Tunnel.State.TOGGLE))
  }

  @Test
  fun doesNotRestartAnAlreadyActiveBlocker() {
    assertFalse(shouldProtectAfterNativeTunnelLoss(true, true, true, Tunnel.State.DOWN))
  }

  @Test
  fun lateCollectorConsumesRealDownReplayedByStateFlow() = runBlocking {
    val state = MutableStateFlow(Tunnel.State.UP)
    state.value = Tunnel.State.DOWN
    var protected = false
    val job = launch(start = CoroutineStart.UNDISPATCHED) {
      state.collect { observed ->
        if (observed == Tunnel.State.DOWN) {
          protected = shouldProtectAfterNativeTunnelLoss(true, true, false, state.value)
        }
      }
    }
    assertTrue(protected)
    job.cancelAndJoin()
  }

  @Test
  fun queuedDownRechecksCurrentStateUnderTransitionMutex() = runBlocking {
    val mutex = Mutex(locked = true)
    var current = Tunnel.State.DOWN
    var protected = false
    val job = launch(start = CoroutineStart.UNDISPATCHED) {
      mutex.withLock {
        protected = shouldProtectAfterNativeTunnelLoss(true, true, false, current)
      }
    }
    current = Tunnel.State.UP // A successful intentional transition wins the lock first.
    mutex.unlock()
    job.join()
    assertFalse(protected)
  }

  @Test
  fun collectorDoesNotStartBlockerAfterQueuedManualRelease() = runBlocking {
    val state = MutableStateFlow(Tunnel.State.UP)
    val mutex = Mutex(locked = true)
    var armed = true
    var retained = true
    var starts = 0
    val job = launch(start = CoroutineStart.UNDISPATCHED) {
      state.collect { observed ->
        if (observed == Tunnel.State.DOWN) mutex.withLock {
          if (shouldProtectAfterNativeTunnelLoss(armed, retained, false, state.value)) starts++
        }
      }
    }
    state.value = Tunnel.State.DOWN
    yield() // The collector is now waiting behind the explicit disconnect.
    armed = false
    retained = false
    mutex.unlock()
    yield()
    assertTrue(starts == 0)
    job.cancelAndJoin()
  }

  @Test
  fun manualReleaseWinsOverQueuedDown() = runBlocking {
    val mutex = Mutex(locked = true)
    var armed = true
    var retained = true
    var protected = false
    val job = launch(start = CoroutineStart.UNDISPATCHED) {
      mutex.withLock {
        protected = shouldProtectAfterNativeTunnelLoss(armed, retained, false, Tunnel.State.DOWN)
      }
    }
    armed = false
    retained = false
    mutex.unlock()
    job.join()
    assertFalse(protected)
  }
}
