package com.vexguard.app.vpn

import org.junit.Assert.*
import org.junit.Test

class VpnPeerIdentityTest {
  @Test fun rejectsPreviousPeerEvenWithFreshTraffic() {
    assertFalse(vpnPeerKeysMatch(listOf("NL"), listOf("DE")))
    assertFalse(vpnPeerKeysMatch(listOf("NL"), listOf("NL", "DE")))
    assertFalse(vpnPeerKeysMatch(listOf("NL"), emptyList()))
    assertFalse(vpnPeerKeysMatch(emptyList(), emptyList()))
    assertFalse(vpnPeerKeysMatch(listOf("NL", "NL"), listOf("NL", "NL")))
    assertTrue(vpnPeerKeysMatch(listOf("NL"), listOf("NL")))
    assertTrue(vpnPeerKeysMatch(listOf("NL", "DE"), listOf("DE", "NL")))
  }
  @Test fun fingerprintsAreStableWithoutExposingTheirInput() {
    assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", vpnIdentityFingerprint("abc"))
    assertNotEquals(vpnIdentityFingerprint("DE"), vpnIdentityFingerprint("NL"))
  }
}
