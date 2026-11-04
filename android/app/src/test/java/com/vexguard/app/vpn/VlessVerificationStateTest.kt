package com.vexguard.app.vpn

import org.junit.Assert.*
import org.junit.Test

class VlessVerificationStateTest {
  private class Fixture {
    var now = 1_000L
    var counter = 0
    val state = VlessVerificationState({ now }, { "connection-${++counter}" })
    fun ready(): VlessVerificationState.Lease {
      state.begin(true)
      state.setCapture(true)
      state.setCoreReady(true)
      return state.lease()
    }
  }

  @Test fun coreStartAndTunAreNotConnectivityProof() {
    val f = Fixture()
    f.ready()
    assertFalse(f.state.snapshot().verified)
    assertEquals(0, f.state.snapshot().verificationEpochMillis)
    assertEquals("probe_pending", f.state.snapshot().verificationReason)
  }

  @Test fun proofRequiresBothOwnedCaptureAndRunningCore() {
    val f = Fixture()
    val first = f.state.begin(true)
    assertFalse(f.state.confirm(first))
    f.state.setCapture(true)
    assertFalse(f.state.confirm(f.state.lease()))
    f.state.setCoreReady(true)
    assertTrue(f.state.confirm(f.state.lease(), 42))
    assertEquals(42L, f.state.snapshot().latencyMs)
  }

  @Test fun lostCaptureImmediatelyInvalidatesAnAlreadyVerifiedConnection() {
    val f = Fixture()
    val lease = f.ready()
    assertTrue(f.state.confirm(lease))
    f.state.setCapture(false)
    assertFalse(f.state.snapshot().verified)
    assertEquals(0, f.state.snapshot().verificationEpochMillis)
    assertFalse(f.state.confirm(lease))
  }

  @Test fun aNetworkHandoverRejectsLateOldProbeAndItsLatency() {
    val f = Fixture()
    val old = f.ready()
    assertTrue(f.state.confirm(old, 900))
    f.state.setCoreReady(false)
    val current = f.state.invalidate("network_unavailable")
    assertFalse(f.state.snapshot().verified)
    assertNull(f.state.snapshot().latencyMs)
    assertFalse(f.state.confirm(old, 800))
    assertFalse(f.state.confirm(current, 15))
    f.state.setCoreReady(true)
    f.now += 100
    assertTrue(f.state.confirm(current, 15))
    assertEquals(15L, f.state.snapshot().latencyMs)
    f.state.fail(old)
    assertTrue(f.state.snapshot().verified)
  }

  @Test fun coreLossRetainsBlockingCaptureButNeverRetainsProof() {
    val f = Fixture()
    f.state.confirm(f.ready())
    f.state.setCoreReady(false)
    assertFalse(f.state.snapshot().verified)
    assertEquals("blocking", f.state.snapshot().leakProtection)
    assertEquals(0, f.state.snapshot().verificationEpochMillis)
  }

  @Test fun explicitDisconnectAndRetainedBlockCannotBeReverifiedByLateWork() {
    for (retain in listOf(false, true)) {
      val f = Fixture()
      val lease = f.ready()
      f.state.confirm(lease)
      f.state.stop(retain)
      assertFalse(f.state.confirm(lease))
      assertFalse(f.state.snapshot().verified)
      assertEquals(if (retain) "blocking" else "off", f.state.snapshot().leakProtection)
      assertEquals(if (retain) "error" else "disconnected", f.state.snapshot().state)
    }
  }

  @Test fun aNewExplicitConnectionCannotInheritThePreviousProof() {
    val f = Fixture()
    val first = f.ready()
    f.state.confirm(first)
    val next = f.state.begin(true)
    assertNotEquals(first.connectionId, next.connectionId)
    assertFalse(f.state.confirm(first))
    assertFalse(f.state.snapshot().verified)
    assertFalse(f.state.confirm(next))
    f.state.setCoreReady(true)
    assertTrue(f.state.confirm(next))
  }

  @Test fun expiredOrFutureDatedProofIsNotHealthyAndHeartbeatRenewsOnlyCurrentLease() {
    val f = Fixture()
    val lease = f.ready()
    f.state.confirm(lease)
    f.now = 999
    assertFalse(f.state.snapshot().verified)
    f.now = 31_001
    assertFalse(f.state.snapshot().verified)
    assertTrue(f.state.confirm(lease))
    assertEquals(31_001, f.state.snapshot().verificationEpochMillis)
    assertTrue(f.state.snapshot().verified)
  }
}
