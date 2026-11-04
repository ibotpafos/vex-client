package com.vexguard.app.vpn

import org.junit.Assert.*
import org.junit.Test

class VlessApplicationPolicyTest {
  @Test fun allAppsCaptureExcludesOnlyTheOwnerControlPlane() {
    val result = VlessApplicationPolicy.admit(emptyList(), false, "com.vexguard.app") { error("No package lookup is needed") }
    assertTrue(result.allowed.isEmpty())
    assertEquals(listOf("com.vexguard.app"), result.excluded)
  }

  @Test fun selectedAppsDoNotCaptureTheOwnerOrBroadenAnEmptySelection() {
    val result = VlessApplicationPolicy.admit(listOf("com.vexguard.app", "com.example.browser", "com.example.browser"), true, "com.vexguard.app") { it == "com.example.browser" }
    assertEquals(listOf("com.example.browser"), result.allowed)
    assertTrue(result.excluded.isEmpty())
    for (packages in listOf(emptyList(), listOf("com.vexguard.app"))) {
      try {
        VlessApplicationPolicy.admit(packages, true, "com.vexguard.app") { true }
        fail("An empty effective selection cannot become a route-all tunnel")
      } catch (_: IllegalArgumentException) { }
    }
  }

  @Test fun missingOrMalformedPackagesFailRatherThanSilentlyRoutingAllApps() {
    for (name in listOf("missing.app", "invalid-package")) {
      try {
        VlessApplicationPolicy.admit(listOf(name), true, "com.vexguard.app") { false }
        fail("Invalid application was admitted")
      } catch (_: IllegalArgumentException) { }
    }
  }
}
