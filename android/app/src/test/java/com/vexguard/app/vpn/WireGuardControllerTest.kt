package com.vexguard.app.vpn

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WireGuardControllerTest {
  @Test
  fun policyOnlyReconnectRollsBackToPriorConfigAndRebindsUnderlyingNetwork() = runBlocking {
    val appliedConfigs = mutableListOf<String>()
    var leakBlockerStarts = 0
    var bindCalls = 0

    val result = applyTunnelConfigWithRollback(
      requestedConfigText = "AllowedIPs = 10.0.0.0/8",
      previousConfigText = "AllowedIPs = 0.0.0.0/0",
      tunnelWasUp = true,
      antiLeakEnabled = true,
      bindSelectedNetwork = { bindCalls += 1 },
      setTunnelDown = {},
      startLeakBlocker = {
        leakBlockerStarts += 1
        true
      },
      setTunnelUp = { configText ->
        appliedConfigs += configText
        if (configText.contains("10.0.0.0/8")) {
          throw IllegalStateException("route set failed")
        }
      },
    )

    assertEquals("AllowedIPs = 0.0.0.0/0", result.activeConfigText)
    assertTrue(result.restoredPreviousConfig)
    assertEquals(listOf("AllowedIPs = 10.0.0.0/8", "AllowedIPs = 0.0.0.0/0"), appliedConfigs)
    assertEquals(1, bindCalls)
    assertEquals(0, leakBlockerStarts)
  }

  @Test
  fun initialConnectFailureArmsLeakBlockerWhenNoPriorConfigExists() = runBlocking {
    var leakBlockerStarts = 0
    var tunnelDownCalls = 0

    try {
      applyTunnelConfigWithRollback(
        requestedConfigText = "AllowedIPs = 10.0.0.0/8",
        previousConfigText = null,
        tunnelWasUp = false,
        antiLeakEnabled = true,
        bindSelectedNetwork = {},
        setTunnelDown = { tunnelDownCalls += 1 },
        startLeakBlocker = {
          leakBlockerStarts += 1
          true
        },
        setTunnelUp = { throw IllegalStateException("route set failed") },
      )
    } catch (error: IllegalStateException) {
      assertEquals("route set failed", error.message)
    }

    assertEquals(1, tunnelDownCalls)
    assertEquals(1, leakBlockerStarts)
  }

  @Test
  fun identicalPolicyReconnectDoesNotReportRollback() = runBlocking {
    val result = applyTunnelConfigWithRollback(
      requestedConfigText = "AllowedIPs = 0.0.0.0/0",
      previousConfigText = "AllowedIPs = 0.0.0.0/0",
      tunnelWasUp = true,
      antiLeakEnabled = true,
      bindSelectedNetwork = {},
      setTunnelDown = {},
      startLeakBlocker = { true },
      setTunnelUp = {},
    )

    assertEquals("AllowedIPs = 0.0.0.0/0", result.activeConfigText)
    assertFalse(result.restoredPreviousConfig)
  }
}
