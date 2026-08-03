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
        "[Peer]\nEndpoint = fi.example.test:443\nPersistentKeepalive = 25",
        "[Peer]\nEndpoint = fi.example.test:51820\nPersistentKeepalive = 25",
      ),
      VpnNetworkRecovery.configCandidates(config),
    )
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
      "[Peer]\nEndpoint = [2001:db8::7]:443",
      VpnNetworkRecovery.configCandidates(config)[1],
    )
  }

  @Test
  fun leavesConfigWithoutEndpointUntouched() {
    val config = "[Peer]\nPersistentKeepalive = 25"

    assertEquals(listOf(config), VpnNetworkRecovery.configCandidates(config))
  }
}
