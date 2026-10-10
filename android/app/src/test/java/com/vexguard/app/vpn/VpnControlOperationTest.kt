package com.vexguard.app.vpn

import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnControlOperationTest {
  private class PausedDispatcher : CoroutineDispatcher() {
    private val queued = ArrayDeque<Runnable>()

    override fun dispatch(context: CoroutineContext, block: Runnable) {
      queued.addLast(block)
    }

    fun drain() {
      while (queued.isNotEmpty()) queued.removeFirst().run()
    }
  }

  @Test
  fun invalidationBeforeDispatchRemovesWatchdogWithoutCallingBackend() {
    val dispatcher = PausedDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    var watchdogScheduled = true
    var backendCalls = 0
    var cleanupCalls = 0
    val job = scope.launchVpnControlOperation({
      watchdogScheduled = false
      cleanupCalls++
    }) {
      backendCalls++
    }
    scope.cancel()
    dispatcher.drain()
    assertTrue(job.isCompleted)
    assertEquals(0, backendCalls)
    assertFalse("An invalidated module left its process-kill watchdog scheduled", watchdogScheduled)
    assertEquals(1, cleanupCalls)
  }

  @Test
  fun alreadyInvalidatedScopeRemovesWatchdogWithoutCallingBackend() {
    val dispatcher = PausedDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    scope.cancel()
    var backendCalls = 0
    var cleanupCalls = 0
    val job = scope.launchVpnControlOperation({ cleanupCalls++ }) { backendCalls++ }
    dispatcher.drain()
    assertTrue(job.isCompleted)
    assertEquals(0, backendCalls)
    assertEquals(1, cleanupCalls)
  }

  @Test
  fun successfulOperationRemovesWatchdogExactlyOnce() {
    val dispatcher = PausedDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    var cleanupCalls = 0
    var backendCalls = 0
    val job = scope.launchVpnControlOperation({ cleanupCalls++ }) { backendCalls++ }
    dispatcher.drain()
    scope.cancel()
    dispatcher.drain()
    assertTrue(job.isCompleted)
    assertEquals(1, backendCalls)
    assertEquals(1, cleanupCalls)
  }

  @Test
  fun failedOperationRemovesWatchdogExactlyOnce() {
    val dispatcher = PausedDispatcher()
    var observedErrors = 0
    val handler = CoroutineExceptionHandler { _, _ -> observedErrors++ }
    val scope = CoroutineScope(SupervisorJob() + dispatcher + handler)
    var cleanupCalls = 0
    val job = scope.launchVpnControlOperation({ cleanupCalls++ }) { error("fixture failure") }
    dispatcher.drain()
    scope.cancel()
    dispatcher.drain()
    assertTrue(job.isCompleted)
    assertEquals(1, observedErrors)
    assertEquals(1, cleanupCalls)
  }

  @Test
  fun cancellationDuringOperationRemovesWatchdogExactlyOnce() {
    val dispatcher = PausedDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    var cleanupCalls = 0
    var entered = false
    val job = scope.launchVpnControlOperation({ cleanupCalls++ }) {
      entered = true
      awaitCancellation()
    }
    dispatcher.drain()
    assertTrue(entered)
    assertEquals(0, cleanupCalls)
    scope.cancel()
    dispatcher.drain()
    assertTrue(job.isCompleted)
    assertEquals(1, cleanupCalls)
  }
}
