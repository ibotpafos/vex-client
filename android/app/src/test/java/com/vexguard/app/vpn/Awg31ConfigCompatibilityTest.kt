package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.util.Base64
import org.amnezia.awg.config.BadConfigException
import org.amnezia.awg.config.Config
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Awg31ConfigCompatibilityTest {
  private val privateKey = Base64.getEncoder().encodeToString(ByteArray(32) { 1.toByte() })
  private val publicKey = Base64.getEncoder().encodeToString(ByteArray(32) { 2.toByte() })
  private val headerKey = Base64.getEncoder().encodeToString(ByteArray(32) { 3.toByte() })

  @Test
  fun roundTripsCompleteAwg31Interface() {
    val source = """
      [Interface]
      PrivateKey = $privateKey
      Address = 10.64.249.2/32
      Jc = 6
      Jmin = 10
      Jmax = 50
      S1 = 12
      S2 = 12
      S3 = 12
      S4 = 12
      H1 = 1000001-1000099
      H2 = 2000001-2000099
      H3 = 3000001-3000099
      H4 = 4000001-4000099
      I1 = <r 8><t><rc 8>
      HeaderProtectionKey = $headerKey
      ContentPaddingAddition = 10-40
      RekeyAfterTime = 120-180
      RekeyTimeout = 2-4
      RejectAfterTime = 180-240
      KeepaliveTimeout = 10-15
      MaxHandshakeAttempts = 10-15
      RandomTrailers = true
      DisableCookies = false

      [Peer]
      PublicKey = $publicKey
      Endpoint = 192.0.2.1:51824
      AllowedIPs = 0.0.0.0/0
    """.trimIndent()

    val rendered = parse(source).toAwgQuickString()
    listOf(
      "HeaderProtectionKey = $headerKey",
      "ContentPaddingAddition = 10-40",
      "RekeyAfterTime = 120-180",
      "RekeyTimeout = 2-4",
      "RejectAfterTime = 180-240",
      "KeepaliveTimeout = 10-15",
      "MaxHandshakeAttempts = 10-15",
      "RandomTrailers = true",
      "DisableCookies = false",
    ).forEach { assertTrue("missing $it", rendered.contains(it)) }
    assertTrue(rendered.contains("PrivateKey = $privateKey\n"))
  }

  @Test
  fun acceptsLegacyAwg30WithoutAwg31OnlyFlags() {
    val source = "[Interface]\nPrivateKey = $privateKey\nAddress = 10.64.252.2/32\nJc = 4\nS1 = 12\nS2 = 12\nS3 = 12\nS4 = 12\nHeaderProtectionKey = $headerKey\n\n[Peer]\nPublicKey = $publicKey\nEndpoint = 192.0.2.1:443\nAllowedIPs = 0.0.0.0/0\n"
    val rendered = parse(source).toAwgQuickString()

    assertTrue(rendered.contains("HeaderProtectionKey = $headerKey"))
    assertFalse(rendered.contains("RandomTrailers"))
    assertFalse(rendered.contains("DisableCookies"))
  }

  @Test
  fun rejectsMalformedHeaderProtectionKey() {
    val error = assertBadConfig("[Interface]\nPrivateKey = $privateKey\nHeaderProtectionKey = invalid-not-base64")

    assertEquals(BadConfigException.Reason.INVALID_KEY, error.reason)
    assertEquals(BadConfigException.Location.HEADER_PROTECTION_KEY, error.location)
  }

  @Test
  fun rejectsUnknownCriticalAwgField() {
    val error = assertBadConfig("[Interface]\nPrivateKey = $privateKey\nFutureCriticalAwg31Field = required")

    assertEquals(BadConfigException.Reason.UNKNOWN_ATTRIBUTE, error.reason)
    assertEquals(BadConfigException.Section.INTERFACE, error.section)
    assertEquals("FutureCriticalAwg31Field", error.text.toString())
  }

  @Test
  fun preservesMalformedAwg31RangeSyntaxAsReportedByOfficialParser() {
    val rendered = parse(
      "[Interface]\nPrivateKey = $privateKey\nContentPaddingAddition = 10--40\nRekeyAfterTime = not-a-range\nRekeyTimeout = 2--4\nRejectAfterTime = 180--240\nKeepaliveTimeout = 10--15\nMaxHandshakeAttempts = 10--15",
    ).toAwgQuickString()

    listOf(
      "ContentPaddingAddition = 10--40",
      "RekeyAfterTime = not-a-range",
      "RekeyTimeout = 2--4",
      "RejectAfterTime = 180--240",
      "KeepaliveTimeout = 10--15",
      "MaxHandshakeAttempts = 10--15",
    ).forEach { assertTrue("official parser changed $it", rendered.contains(it)) }
  }

  @Test
  fun debugStringRedactsSyntheticPrivateAndHeaderKeys() {
    val debug = parse("[Interface]\nPrivateKey = $privateKey\nHeaderProtectionKey = $headerKey").toString()

    assertFalse(debug.contains(privateKey))
    assertFalse(debug.contains(headerKey))
  }

  private fun parse(source: String): Config =
    Config.parse(ByteArrayInputStream(source.toByteArray(StandardCharsets.UTF_8)))

  private fun assertBadConfig(source: String): BadConfigException =
    try {
      parse(source)
      fail("official parser accepted malformed profile")
      throw AssertionError("unreachable")
    } catch (error: BadConfigException) {
      error
    }
}
