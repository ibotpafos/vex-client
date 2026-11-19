package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnEngineRevisionTest {
  @Test
  fun legacyIntentIsUnknownUntilAnExplicitCommandAndSurvivesReload() {
    var persisted: Boolean? = null
    val state = VpnEngineRevision(persisted) { persisted = it }
    assertNull(state.awgWanted())
    state.next(true)
    assertTrue(state.awgWanted() == true)
    assertTrue(VpnEngineRevision(persisted) { persisted = it }.awgWanted() == true)
  }

  @Test
  fun manualStopWithdrawsIntentAndFencesAnOlderPendingConnect() {
    var persisted: Boolean? = null
    val state = VpnEngineRevision(persisted) { persisted = it }
    val connect = state.next(true)
    val stop = state.next(false)
    assertEquals(stop, state.get())
    assertFalse(state.awgWanted() == true)
    assertFalse(state.setAwgWanted(connect, true))
    assertEquals(false, persisted)
    assertEquals(false, VpnEngineRevision(persisted) { persisted = it }.awgWanted())
  }

  @Test
  fun admittedTransportSwitchCanWithdrawOnlyItsCurrentAwgIntent() {
    var persisted: Boolean? = null
    val state = VpnEngineRevision(persisted) { persisted = it }
    state.next(true)
    val vless = state.next()
    assertTrue(state.awgWanted() == true)
    assertTrue(state.setAwgWanted(vless, false))
    state.next(true)
    assertFalse(state.setAwgWanted(vless, false))
    assertTrue(state.awgWanted() == true)
  }

  @Test
  fun failedPersistenceCannotAdvanceRevisionOrPublishANewIntent() {
    val state = VpnEngineRevision(null) { error("fixture storage failure") }
    try {
      state.next(true)
      throw AssertionError("A failed durable intent write was accepted")
    } catch (_: IllegalStateException) {
      assertEquals(0L, state.get())
      assertNull(state.awgWanted())
    }
  }
}
