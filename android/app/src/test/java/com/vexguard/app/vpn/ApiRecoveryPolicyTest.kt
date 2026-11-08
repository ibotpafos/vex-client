package com.vexguard.app.vpn

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApiRecoveryPolicyTest {
  @Test fun ordinaryMutationMethodsAndByteLimitsAreBounded() {
    for (method in listOf("POST", "PUT", "PATCH", "DELETE", "OPTIONS"))
      assertTrue(method, ApiRecoveryPolicy.acceptsMutationMethod(method))
    for (method in listOf("GET", "HEAD", "TRACE", "CONNECT", "post", ""))
      assertFalse(method, ApiRecoveryPolicy.acceptsMutationMethod(method))
    assertTrue(ApiRecoveryPolicy.acceptsBodySize(0, true))
    assertTrue(ApiRecoveryPolicy.acceptsBodySize(6 * 1024 * 1024, true))
    assertFalse(ApiRecoveryPolicy.acceptsBodySize(6 * 1024 * 1024 + 1, true))
    assertTrue(ApiRecoveryPolicy.acceptsBodySize(2 * 1024 * 1024, false))
    assertFalse(ApiRecoveryPolicy.acceptsBodySize(2 * 1024 * 1024 + 1, false))
    assertFalse(ApiRecoveryPolicy.acceptsBodySize(-1, true))
  }

  @Test fun advertisedRecoveryHostsMatchExactNativeAdmission() {
    val expected = listOf("vexguard.app", "www.vexguard.app", "api.vexguard.app", "api2.vexguard.app")
    assertEquals(expected, ApiRecoveryPolicy.recoveryHosts())
    for (host in ApiRecoveryPolicy.recoveryHosts()) {
      assertTrue(host, ApiRecoveryPolicy.acceptsUrl("https://$host/v1/vpn/profile"))
    }
    // A consumer cannot mutate a snapshot to widen native admission.
    val snapshot = ApiRecoveryPolicy.recoveryHosts() as MutableList<String>
    snapshot.add("evil.test")
    assertEquals(expected, ApiRecoveryPolicy.recoveryHosts())
    assertFalse(ApiRecoveryPolicy.acceptsUrl("https://evil.test/v1/vpn/profile"))
  }

  @Test fun onlyFirstPartyHttpsApiPathsCanBypassACapturedTunnel() {
    assertTrue(ApiRecoveryPolicy.acceptsUrl("https://vexguard.app/v1/vpn/profile?fresh=1"))
    assertTrue(ApiRecoveryPolicy.acceptsUrl("https://api.vexguard.app:443/v1/devices"))
    for (url in listOf("http://vexguard.app/v1/profile", "https://vexguard.app.evil.test/v1/profile",
      "https://evil.test/v1/profile", "https://vexguard.app:444/v1/profile", "https://user:secret@vexguard.app/v1/profile",
      "https://vexguard.app/dashboard", "https://vexguard.app/v1/../admin", "https://vexguard.app/v1/%2e%2e/admin",
      "https://vexguard.app/v1/%2f..%2fadmin", "https://vexguard.app/v1/profile#fragment")) {
      assertFalse(url, ApiRecoveryPolicy.acceptsUrl(url))
    }
  }

  @Test fun secondaryApiOriginKeepsExactHttpsHostAndPortScope() {
    for (url in listOf("https://api2.vexguard.app/v1/vpn/profile?fresh=1",
      "https://api2.vexguard.app:443/v1/devices")) {
      assertTrue(url, ApiRecoveryPolicy.acceptsUrl(url))
    }
    for (url in listOf("http://api2.vexguard.app/v1/profile", "https://api2.vexguard.app:80/v1/profile",
      "https://api2.vexguard.app:444/v1/profile", "https://api2.vexguard.app:0/v1/profile",
      "https://api2.vexguard.app.evil.test/v1/profile", "https://evil.api2.vexguard.app/v1/profile",
      "https://api2-vexguard.app/v1/profile", "https://api3.vexguard.app/v1/profile",
      "https://api2.vexguard.app./v1/profile", "https://api2.vexguard.app@evil.test/v1/profile",
      "https://user:secret@api2.vexguard.app/v1/profile", "https://api2.vexguard.app/dashboard",
      "https://api2.vexguard.app/v1/../admin", "https://api2.vexguard.app/v1/%2e%2e/admin",
      "https://api2.vexguard.app/v1/%2f..%2fadmin", "https://api2.vexguard.app/v1/profile#fragment")) {
      assertFalse(url, ApiRecoveryPolicy.acceptsUrl(url))
    }
  }

  @Test fun headersCannotOverrideTheTlsOriginOrInjectAnotherRequest() {
    assertTrue(ApiRecoveryPolicy.acceptsHeader("Authorization", "Bearer fixture-token"))
    assertTrue(ApiRecoveryPolicy.acceptsHeader("Idempotency-Key", "fixture"))
    for (name in listOf("Host", "Connection", "Content-Length", "TRANSFER-ENCODING", "Proxy-Authorization", "Upgrade", "Bad Header"))
      assertFalse(name, ApiRecoveryPolicy.acceptsHeader(name, "fixture"))
    assertFalse(ApiRecoveryPolicy.acceptsHeader("X-Fixture", "safe\r\nHost: evil.test"))
    assertFalse(ApiRecoveryPolicy.acceptsHeader("X-Fixture", "x".repeat(16_385)))
  }

  @Test fun localeCannotChangeOriginAndHeaderValidation() {
    val previous = Locale.getDefault()
    try {
      Locale.setDefault(Locale("tr", "TR"))
      assertTrue(ApiRecoveryPolicy.acceptsUrl("https://API.VEXGUARD.APP/v1/profile"))
      assertTrue(ApiRecoveryPolicy.acceptsUrl("https://API2.VEXGUARD.APP/v1/profile"))
      assertFalse(ApiRecoveryPolicy.acceptsHeader("TRANSFER-ENCODING", "chunked"))
    } finally { Locale.setDefault(previous) }
  }

  @Test fun cancellationIdsAreBoundedOpaqueCounters() {
    assertTrue(ApiRecoveryPolicy.acceptsRequestId("api-1793930000000-1"))
    for (id in listOf("", "api-1", "api-1-other", "api--1-1", "api-1-" + "1".repeat(13)))
      assertFalse(id, ApiRecoveryPolicy.acceptsRequestId(id))
  }
}
