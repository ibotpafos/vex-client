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
  private val presharedKey = Base64.getEncoder().encodeToString(ByteArray(32) { 4.toByte() })

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
      I2 = <r 9><t><rc 9>
      I3 = <r 10><t><rc 10>
      I4 = <r 11><t><rc 11>
      I5 = <r 12><t><rc 12>
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
      PresharedKey = $presharedKey
      Endpoint = 192.0.2.1:51824
      AllowedIPs = 0.0.0.0/0
      PersistentKeepalive = 25
    """.trimIndent()
    val expected = """
      [Interface]
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
      I2 = <r 9><t><rc 9>
      I3 = <r 10><t><rc 10>
      I4 = <r 11><t><rc 11>
      I5 = <r 12><t><rc 12>
      HeaderProtectionKey = $headerKey
      ContentPaddingAddition = 10-40
      RekeyAfterTime = 120-180
      RekeyTimeout = 2-4
      RejectAfterTime = 180-240
      KeepaliveTimeout = 10-15
      MaxHandshakeAttempts = 10-15
      RandomTrailers = true
      DisableCookies = false
      PrivateKey = $privateKey

      [Peer]
      AllowedIPs = 0.0.0.0/0
      Endpoint = 192.0.2.1:51824
      PersistentKeepalive = 25
      PreSharedKey = $presharedKey
      PublicKey = $publicKey
    """.trimIndent() + "\n"

    assertEquals(expected, parse(source).toAwgQuickString())
    assertEquals(expected, AwgConfigSafety.parseForActivation(source).toAwgQuickString())
  }

  @Test
  fun acceptsLegacyAwg30WithoutAwg31OnlyFlags() {
    val source = """
      [Interface]
      PrivateKey = $privateKey
      Address = 10.64.252.2/32
      Jc = 4
      S1 = 12
      S2 = 12
      S3 = 12
      S4 = 12
      HeaderProtectionKey = $headerKey

      [Peer]
      PublicKey = $publicKey
      Endpoint = 192.0.2.1:443
      AllowedIPs = 0.0.0.0/0
    """.trimIndent()
    val expected = """
      [Interface]
      Address = 10.64.252.2/32
      Jc = 4
      S1 = 12
      S2 = 12
      S3 = 12
      S4 = 12
      HeaderProtectionKey = $headerKey
      PrivateKey = $privateKey

      [Peer]
      AllowedIPs = 0.0.0.0/0
      Endpoint = 192.0.2.1:443
      PublicKey = $publicKey
    """.trimIndent() + "\n"

    assertEquals(expected, parse(source).toAwgQuickString())
    assertEquals(expected, AwgConfigSafety.parseForActivation(source).toAwgQuickString())
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
  fun rejectsMalformedAwg31RangesBeforeActivationWithoutChangingPriorState() {
    val fields = listOf(
      "ContentPaddingAddition",
      "RekeyAfterTime",
      "RekeyTimeout",
      "RejectAfterTime",
      "KeepaliveTimeout",
      "MaxHandshakeAttempts",
    )
    val malformedValues = listOf("10--40", "not-a-range", "2-", "-4", "10-2", "-1", "1-2-3")

    fields.forEach { field ->
      malformedValues.forEach { malformedValue ->
        val source = "[Interface]\nPrivateKey = $privateKey\n$field = $malformedValue"
        assertTrue("official parser unexpectedly rejected $field=$malformedValue", parse(source).toAwgQuickString().contains("$field = $malformedValue"))

        var backendActivationCalls = 0
        val priorTunnelState = "UP"
        try {
          AwgConfigSafety.parseForActivation(source)
          backendActivationCalls += 1
          fail("activation config accepted $field=$malformedValue")
        } catch (_: AwgConfigValidationException) {
        }
        assertEquals(0, backendActivationCalls)
        assertEquals("UP", priorTunnelState)
      }
    }
  }

  @Test
  fun acceptsDocumentedAwg31IntegerAndAscendingRangeForms() {
    val fields = listOf(
      "ContentPaddingAddition",
      "RekeyAfterTime",
      "RekeyTimeout",
      "RejectAfterTime",
      "KeepaliveTimeout",
      "MaxHandshakeAttempts",
    )

    listOf("0", "1", "10-40").forEach { value ->
      val source = buildString {
        appendLine("[Interface]")
        appendLine("PrivateKey = $privateKey")
        fields.forEach { appendLine("$it = $value") }
      }
      val rendered = AwgConfigSafety.parseForActivation(source).toAwgQuickString()
      fields.forEach { assertTrue("missing $it=$value", rendered.contains("$it = $value")) }
    }
  }

  @Test
  fun redactsConfigurationSecretsAtTheErrorReportingBoundary() {
    val rawError = """
      backend error
      PrivateKey = $privateKey
      PresharedKey = $presharedKey
      HeaderProtectionKey = $headerKey
      Endpoint = 192.0.2.1:51824
    """.trimIndent()

    val redacted = VpnLogRedaction.redact(rawError)
    val sanitizedThrowable = VpnLogRedaction.sanitizedThrowable(redacted)

    assertFalse(redacted.contains(privateKey))
    assertFalse(redacted.contains(presharedKey))
    assertFalse(redacted.contains(headerKey))
    assertFalse(sanitizedThrowable.stackTraceToString().contains(privateKey))
    assertFalse(sanitizedThrowable.stackTraceToString().contains(presharedKey))
    assertFalse(sanitizedThrowable.stackTraceToString().contains(headerKey))
    assertTrue(redacted.contains("Endpoint = 192.0.2.1:51824"))
    assertTrue(redacted.contains("PrivateKey = [REDACTED]"))
    assertTrue(redacted.contains("PresharedKey = [REDACTED]"))
    assertTrue(redacted.contains("HeaderProtectionKey = [REDACTED]"))
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
