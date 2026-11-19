package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnVerificationTimersTest {
  @Test
  fun expiryCompletesOnceAndCancellationFencesAnAlreadyQueuedCallback() {
    val tasks = mutableListOf<Runnable>()
    val removed = mutableListOf<Runnable>()
    val results = mutableListOf<Boolean>()
    val timers = VpnVerificationTimers({ task, _ -> tasks.add(task); true }, { removed.add(it) })
    assertTrue(timers.schedule("verify-1", 250.0) { results.add(it) })
    val old = tasks.single()
    timers.cancel("verify-1")
    timers.cancel("verify-1")
    assertEquals(listOf(false), results)
    assertEquals(listOf(old), removed)
    assertTrue(timers.schedule("verify-1", 250.0) { results.add(it) })
    old.run()
    assertEquals(listOf(false), results)
    tasks.last().run()
    tasks.last().run()
    assertEquals(listOf(false, true), results)
  }

  @Test
  fun teardownResolvesEveryPendingPromiseAndQueuedCallbacksStayInert() {
    val tasks = mutableListOf<Runnable>()
    val results = mutableListOf<Boolean>()
    val timers = VpnVerificationTimers({ task, _ -> tasks.add(task); true }, {})
    for (id in 1..3) assertTrue(timers.schedule("verify-$id", 1.0) { results.add(it) })
    timers.clear()
    timers.clear()
    tasks.forEach { it.run() }
    assertEquals(listOf(false, false, false), results)
  }

  @Test
  fun registrationBoundsRejectInvalidDuplicateAndExcessTimers() {
    val tasks = mutableListOf<Runnable>()
    val timers = VpnVerificationTimers({ task, _ -> tasks.add(task); true }, {})
    for (id in listOf("", "verify-0", "verify--1", "other-1", "verify-1234567890123456")) {
      assertFalse(timers.schedule(id, 1.0) {})
    }
    for (delay in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY, 60_001.0)) {
      assertFalse(timers.schedule("verify-1", delay) {})
    }
    for (id in 1..128) assertTrue(timers.schedule("verify-$id", 60_000.0) {})
    assertFalse(timers.schedule("verify-1", 0.0) {})
    assertFalse(timers.schedule("verify-129", 0.0) {})
    tasks.first().run()
    assertTrue(timers.schedule("verify-129", 0.0) {})
    timers.clear()
  }

  @Test
  fun failedHandlerRegistrationDoesNotRetainTheIdOrResolveAnUnregisteredPromise() {
    var behavior = 0
    var completions = 0
    val timers = VpnVerificationTimers({ _, _ ->
      when (behavior++) { 0 -> false; 1 -> throw IllegalStateException("fixture handler stopped"); else -> true }
    }, {})
    assertFalse(timers.schedule("verify-1", 1.0) { completions++ })
    assertFalse(timers.schedule("verify-1", 1.0) { completions++ })
    assertTrue(timers.schedule("verify-1", 1.0) { completions++ })
    assertEquals(0, completions)
    timers.clear()
    assertEquals(1, completions)
  }
}
