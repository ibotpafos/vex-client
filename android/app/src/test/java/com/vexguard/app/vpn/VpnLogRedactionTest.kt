package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class VpnLogRedactionTest {
  @Test
  fun bugsinkMetadataUsesBoundedVocabularyAndNeverInput() {
    val raw = "VPN_CONNECT_FAILED private@example.test PrivateKey = secret"
    val category = VpnLogRedaction.telemetryErrorCategory("VPN_CONNECT_FAILED")
    val stage = VpnLogRedaction.telemetryErrorStage("VPN_CONNECT_FAILED")
    val error = VpnLogRedaction.telemetryThrowable(category, stage)

    assertEquals("connection", category)
    assertEquals("connect", stage)
    assertEquals("VPN connection failure at connect", error.message)
    assertFalse(error.stackTraceToString().contains(raw))
  }

  @Test
  fun unknownCodesCannotBecomeTagsOrExceptionMessages() {
    val untrusted = "VPN_PRIVATE_TOKEN_example@example.test"
    val category = VpnLogRedaction.telemetryErrorCategory(untrusted)
    val stage = VpnLogRedaction.telemetryErrorStage(untrusted)
    val error = VpnLogRedaction.telemetryThrowable(category, stage)

    assertEquals("unknown", category)
    assertEquals("unknown", stage)
    assertFalse(error.message.orEmpty().contains("example"))
  }
}
