package com.vexguard.app.vpn

import java.util.Locale
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApiRecoveryPolicyTest {
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
      assertFalse(ApiRecoveryPolicy.acceptsHeader("TRANSFER-ENCODING", "chunked"))
    } finally { Locale.setDefault(previous) }
  }

  @Test fun cancellationIdsAreBoundedOpaqueCounters() {
    assertTrue(ApiRecoveryPolicy.acceptsRequestId("api-1793930000000-1"))
    for (id in listOf("", "api-1", "api-1-other", "api--1-1", "api-1-" + "1".repeat(13)))
      assertFalse(id, ApiRecoveryPolicy.acceptsRequestId(id))
  }
}
