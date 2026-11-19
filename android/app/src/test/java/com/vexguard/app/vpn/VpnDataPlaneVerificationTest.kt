package com.vexguard.app.vpn

import org.junit.Assert.*
import org.junit.Test

class VpnDataPlaneVerificationTest {
  @Test fun noHandshakeOrOldProofCanConfirmAnotherPeerOrNetwork() {
    val proof = VpnDataPlaneVerification()
    assertFalse(proof.status("", 1L, 100L).verified)
    val de = proof.begin("DE", 1L, 100L)!!
    assertFalse(proof.status("DE", 1L, 200L).verified)
    assertTrue(proof.complete(de, 0, 300L))
    assertTrue(proof.status("DE", 1L, 301L).verified)
    assertFalse(proof.status("NL", 1L, 302L).verified)
    assertFalse(proof.complete(de, 0, 303L))
    val nl = proof.begin("NL", 1L, 304L)!!
    assertFalse(proof.status("NL", 2L, 305L).verified)
    assertFalse(proof.complete(nl, 0, 306L))
    assertFalse(proof.status("NL", 2L, 307L).verified)
  }

  @Test fun dnsAndHttpsFailuresStayUnverifiedAndRetryIsBounded() {
    for ((code, reason) in listOf(1 to "dns_failed", 2 to "https_failed", 3 to "data_plane_unavailable")) {
      val proof = VpnDataPlaneVerification()
      val attempt = proof.begin("NL", 1L, 100L)!!
      assertNull(proof.begin("NL", 1L, 101L))
      assertTrue(proof.complete(attempt, code, 200L))
      assertEquals(VpnDataPlaneVerification.Status(false, reason), proof.status("NL", 1L, 201L))
      assertNull(proof.begin("NL", 1L, 3199L))
      assertNotNull(proof.begin("NL", 1L, 3200L))
    }
  }

  @Test fun proofExpiresAndFailedRefreshRevokesIt() {
    val proof = VpnDataPlaneVerification()
    assertTrue(proof.complete(proof.begin("NL", 1L, 0L)!!, 0, 100L))
    assertNull(proof.begin("NL", 1L, 45099L))
    val refresh = proof.begin("NL", 1L, 45100L)!!
    assertTrue(proof.status("NL", 1L, 45101L).verified)
    assertFalse(proof.status("NL", 1L, 60100L).verified)
    assertTrue(proof.complete(refresh, 2, 60101L))
    assertEquals("https_failed", proof.status("NL", 1L, 60102L).reason)
  }

  @Test fun disconnectAndReusedHandleCannotAdmitAnOldCompletion() {
    val proof = VpnDataPlaneVerification()
    val old = proof.begin("NL", 1L, 0L)!!
    proof.clear()
    val next = proof.begin("NL", 1L, 1L)!!
    assertNotEquals(old.sequence, next.sequence)
    assertFalse(proof.complete(old, 0, 2L))
    assertTrue(proof.complete(next, 0, 3L))
  }
}
