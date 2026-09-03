package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnNetworkRecoveryTest {

  @Test
  fun reusesAnActiveTunnelForAnIdenticalConnectRequest() {
    assertTrue(
      shouldReuseActiveVpnTunnel(
        isTunnelUp = true,
        lastConfigText = "[Interface]\\nPrivateKey = key",
        requestedConfigText = "[Interface]\\nPrivateKey = key",
        antiLeakArmed = true,
        antiLeakEnabled = true,
        leakBlockerActive = false,
      ),
    )
  }

  @Test
  fun doesNotReuseTunnelWhenProtectionOrConfigChanged() {
    assertFalse(
      shouldReuseActiveVpnTunnel(
        isTunnelUp = true,
        lastConfigText = "first",
        requestedConfigText = "second",
        antiLeakArmed = true,
        antiLeakEnabled = true,
        leakBlockerActive = false,
      ),
    )
    assertFalse(
      shouldReuseActiveVpnTunnel(
        isTunnelUp = true,
        lastConfigText = "same",
        requestedConfigText = "same",
        antiLeakArmed = false,
        antiLeakEnabled = true,
        leakBlockerActive = false,
      ),
    )
  }
  @Test
  fun preservesCurrentEndpointThenAddsFallbackPorts() {
    val config = "[Peer]\nEndpoint = fi.example.test:8443\nPersistentKeepalive = 25"

    assertEquals(
      listOf(
        "[Peer]\nEndpoint = fi.example.test:8443\nPersistentKeepalive = 25",
        "[Peer]\nEndpoint = fi.example.test:51821\nPersistentKeepalive = 25",
        "[Peer]\nEndpoint = fi.example.test:443\nPersistentKeepalive = 25",
      ),
      VpnNetworkRecovery.configCandidates(config),
    )
  }

  @Test
  fun preservesEveryAwg31FieldAcrossRecoveryCandidates() {
    val config = "[Interface]\nI1 = <r 8><t><rc 8>\nHeaderProtectionKey = synthetic\nContentPaddingAddition = 10-40\nRandomTrailers = true\nDisableCookies = false\n[Peer]\nEndpoint = de.example.test:51824"
    val candidates = VpnNetworkRecovery.configCandidates(config)
    val endpointPattern = Regex("(?m)^Endpoint\\s*=\\s*.+$")
    val expectedOutsideEndpoint = config.replace(endpointPattern, "Endpoint = <candidate>")

    candidates.forEach { candidate ->
      assertEquals(expectedOutsideEndpoint, candidate.replace(endpointPattern, "Endpoint = <candidate>"))
      assertTrue(candidate.contains("I1 = <r 8><t><rc 8>"))
      assertTrue(candidate.contains("HeaderProtectionKey = synthetic"))
      assertTrue(candidate.contains("ContentPaddingAddition = 10-40"))
      assertTrue(candidate.contains("RandomTrailers = true"))
      assertTrue(candidate.contains("DisableCookies = false"))
      assertFalse(candidate.contains(":51820"))
    }
  }

  @Test
  fun keepsRecoveryOnTheAwg3ListenersOnly() {
    // Since the AWG2 retirement even configs without HeaderProtectionKey must
    // never fall through to the retired 51820 listener.
    val config = "[Peer]\nEndpoint = fi.example.test:8443\nPersistentKeepalive = 25"
    val candidates = VpnNetworkRecovery.configCandidates(config)

    assertFalse(candidates.any { it.contains(":51820") })
  }

  @Test
  fun doesNotDuplicateExistingFallbackPort() {
    val config = "[Peer]\nEndpoint = 203.0.113.7:443"

    assertEquals(2, VpnNetworkRecovery.configCandidates(config).size)
  }

  @Test
  fun formatsIpv6EndpointsWithBrackets() {
    val config = "[Peer]\nEndpoint = [2001:db8::7]:8443"

    assertEquals(
      listOf(
        "[Peer]\nEndpoint = [2001:db8::7]:8443",
        "[Peer]\nEndpoint = [2001:db8::7]:51821",
        "[Peer]\nEndpoint = [2001:db8::7]:443",
      ),
      VpnNetworkRecovery.configCandidates(config),
    )
  }

  @Test
  fun leavesConfigWithoutEndpointUntouched() {
    val config = "[Peer]\nPersistentKeepalive = 25"

    assertEquals(listOf(config), VpnNetworkRecovery.configCandidates(config))
  }
}
