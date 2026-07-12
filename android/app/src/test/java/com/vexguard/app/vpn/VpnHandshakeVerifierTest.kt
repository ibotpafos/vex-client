package com.vexguard.app.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class VpnHandshakeVerifierTest {
  @Test
  fun outgoingTrafficWithoutHandshakeIsNotVerified() {
    assertFalse(VpnHandshakeVerifier.isVerified(0L))
  }

  @Test
  fun positiveHandshakeTimestampIsVerified() {
    assertTrue(VpnHandshakeVerifier.isVerified(1L))
  }

  @Test
  fun backendHandshakeIsUsedWhenPeerStatsLagBehind() {
    assertEquals(1_725_000L, VpnHandshakeVerifier.latestHandshakeEpochMillis(0L, 1_725L))
  }

  @Test
  fun newestHandshakeSourceWins() {
    assertEquals(2_000_500L, VpnHandshakeVerifier.latestHandshakeEpochMillis(2_000_500L, 2_000L))
  }

  @Test
  fun backendErrorsAreNotTreatedAsHandshakes() {
    assertEquals(0L, VpnHandshakeVerifier.latestHandshakeEpochMillis(0L, -2L))
  }

}
