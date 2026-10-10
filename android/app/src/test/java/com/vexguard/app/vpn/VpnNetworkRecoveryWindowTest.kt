package com.vexguard.app.vpn

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnNetworkRecoveryWindowTest {
  private class Fixture {
    var nowMs = 1_000L
    var expirationCount = 0
    val window = VpnNetworkRecoveryWindow(
      VpnNetworkRecoveryTiming.MAX_PENDING_MS,
      { nowMs },
      { expirationCount++ },
    )
  }

  @Test
  fun queuedRecoveryDoesNotDeferControlWatchdog() = runBlocking {
    val fixture = Fixture()
    val mutex = Mutex(locked = true)
    var entered = false
    val recovery = launch(start = CoroutineStart.UNDISPATCHED) {
      runVpnNetworkRecovery(mutex, fixture.window, 0L) {
        entered = true
        awaitCancellation()
      }
    }
    try {
      assertFalse(entered)
      assertFalse("A recovery waiting behind a hung control operation must not defer its watchdog", fixture.window.isPending())
      mutex.unlock()
      yield()
      assertTrue(entered)
      assertTrue(fixture.window.isPending())
    } finally {
      recovery.cancelAndJoin()
    }
    assertFalse(fixture.window.isPending())
  }

  @Test
  fun debouncingRecoveryDoesNotDeferControlWatchdog() = runBlocking {
    val fixture = Fixture()
    val recovery = launch(start = CoroutineStart.UNDISPATCHED) {
      runVpnNetworkRecovery(Mutex(), fixture.window, VpnNetworkRecoveryTiming.DEBOUNCE_MS) {
        error("Debouncing recovery entered the backend")
      }
    }
    try {
      assertFalse(fixture.window.isPending())
    } finally {
      recovery.cancelAndJoin()
    }
    assertEquals(0, fixture.expirationCount)
  }

  @Test
  fun cancelledQueuedRecoveryNeverStartsAPendingWindow() = runBlocking {
    val fixture = Fixture()
    val recovery = launch(start = CoroutineStart.UNDISPATCHED) {
      runVpnNetworkRecovery(Mutex(locked = true), fixture.window, 0L) {
        error("Queued recovery entered the backend")
      }
    }
    recovery.cancelAndJoin()
    assertFalse(fixture.window.isPending())
    assertEquals(0, fixture.expirationCount)
  }

  @Test
  fun pendingWindowPreservesNormalRecoveryAndExpiresAtExistingBudget() {
    val fixture = Fixture()
    fixture.window.begin()
    fixture.nowMs += VpnNetworkRecoveryTiming.MAX_PENDING_MS - 1
    assertTrue(fixture.window.isPending())
    fixture.nowMs++
    assertFalse("Native recovery must not postpone the control watchdog forever", fixture.window.isPending())
    assertEquals(1, fixture.expirationCount)
  }

  @Test
  fun repeatedWatchdogChecksCannotRenewAStuckRecovery() {
    val fixture = Fixture()
    fixture.window.begin()
    repeat(100) { check ->
      fixture.nowMs = 1_000L + (check + 1) * 5_000L
      assertEquals(fixture.nowMs < 1_000L + VpnNetworkRecoveryTiming.MAX_PENDING_MS, fixture.window.isPending())
    }
    assertEquals(1, fixture.expirationCount)
  }

  @Test
  fun expiredWindowCannotReturnUntilANewRecoveryBegins() {
    val fixture = Fixture()
    val expiredGeneration = fixture.window.begin()
    fixture.nowMs += VpnNetworkRecoveryTiming.MAX_PENDING_MS
    assertFalse(fixture.window.isPending())
    fixture.nowMs = 0L
    assertFalse(fixture.window.isPending())
    fixture.window.begin()
    fixture.window.finish(expiredGeneration)
    assertTrue(fixture.window.isPending())
    assertEquals(1, fixture.expirationCount)
  }

  @Test
  fun completionOfOldGenerationDoesNotClearNewRecovery() {
    val fixture = Fixture()
    val oldGeneration = fixture.window.begin()
    fixture.nowMs += 5_000L
    val newGeneration = fixture.window.begin()
    fixture.window.finish(oldGeneration)
    assertTrue(fixture.window.isPending())
    fixture.window.finish(newGeneration)
    assertFalse(fixture.window.isPending())
    assertEquals(0, fixture.expirationCount)
  }

  @Test
  fun successfulRecoveryClearsWindowAndReturnsResult() = runBlocking {
    val fixture = Fixture()
    val result = runVpnNetworkRecovery(Mutex(), fixture.window, 0L) {
      assertTrue(fixture.window.isPending())
      "recovered"
    }
    assertEquals("recovered", result)
    assertFalse(fixture.window.isPending())
  }

  @Test
  fun failedRecoveryClearsWindowWithoutHidingError() = runBlocking {
    val fixture = Fixture()
    val expected = IllegalStateException("fixture recovery failure")
    val actual = runCatching {
      runVpnNetworkRecovery(Mutex(), fixture.window, 0L) { throw expected }
    }.exceptionOrNull()
    assertTrue(expected === actual)
    assertFalse(fixture.window.isPending())
  }

  @Test
  fun cancelledActiveRecoveryClearsItsWindow() = runBlocking {
    val fixture = Fixture()
    val recovery = launch(start = CoroutineStart.UNDISPATCHED) {
      runVpnNetworkRecovery(Mutex(), fixture.window, 0L) { awaitCancellation() }
    }
    assertTrue(fixture.window.isPending())
    recovery.cancelAndJoin()
    assertFalse(fixture.window.isPending())
    assertEquals(0, fixture.expirationCount)
  }
}
