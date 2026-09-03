package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.coroutines.runBlocking
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
  fun acceptsCompleteLegacyAwg30WithoutAwg31OnlyFlags() {
    val source = """
      [Interface]
      PrivateKey = $privateKey
      Address = 10.64.252.2/32
      Jc = 4
      Jmin = 8
      Jmax = 32
      S1 = 12
      S2 = 13
      S3 = 14
      S4 = 15
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

      [Peer]
      PublicKey = $publicKey
      PresharedKey = $presharedKey
      Endpoint = 192.0.2.1:443
      AllowedIPs = 0.0.0.0/0
      PersistentKeepalive = 25
    """.trimIndent()
    val expected = """
      [Interface]
      Address = 10.64.252.2/32
      Jc = 4
      Jmin = 8
      Jmax = 32
      S1 = 12
      S2 = 13
      S3 = 14
      S4 = 15
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
      PrivateKey = $privateKey

      [Peer]
      AllowedIPs = 0.0.0.0/0
      Endpoint = 192.0.2.1:443
      PersistentKeepalive = 25
      PreSharedKey = $presharedKey
      PublicKey = $publicKey
    """.trimIndent() + "\n"

    val rendered = parse(source).toAwgQuickString()
    assertEquals(expected, rendered)
    assertEquals(expected, AwgConfigSafety.parseForActivation(source).toAwgQuickString())
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
  fun productionActivationGateRejectsBeforeTunnelBackendBlockerOrRoutedStateMutation() = runBlocking {
    val priorRoutedApplications = mutableListOf("com.vexguard.existing")
    val mutation = RecordingVpnMutation(priorRoutedApplications)
    val invalidConfig = "[Interface]\nPrivateKey = $privateKey\nRekeyTimeout = 10-2"

    try {
      VpnConfigActivation.afterValidation(invalidConfig) { config ->
        mutation.replaceRoutedApplications(listOf("com.vexguard.replacement"))
        mutation.setTunnelDown()
        mutation.startLeakBlocker()
        mutation.setBackendUp(config)
      }
      fail("invalid replacement passed the controller activation gate")
    } catch (_: AwgConfigValidationException) {
    }

    assertEquals(listOf("com.vexguard.existing"), priorRoutedApplications)
    assertEquals(0, mutation.tunnelMutations)
    assertEquals(0, mutation.blockerMutations)
    assertEquals(0, mutation.backendMutations)

    try {
      VpnConfigActivation.parseRecoveryCandidates(invalidConfig)
      fail("invalid recovery candidate passed the controller recovery gate")
    } catch (_: AwgConfigValidationException) {
    }
    assertEquals(0, mutation.tunnelMutations)
    assertEquals(0, mutation.blockerMutations)
    assertEquals(0, mutation.backendMutations)
  }

  @Test
  fun dispatchesOnlyFreshCauselessSanitizedErrorsToEveryVpnBoundary() {
    val raw = "backend failure PrivateKey = $privateKey\nPresharedKey = $presharedKey\nHeaderProtectionKey = $headerKey\nEndpoint = 192.0.2.1:51824"
    val deliveries = mutableListOf<DeliveredVpnError>()

    VpnErrorDispatcher.dispatch(
      code = "VPN_CONNECT_FAILED",
      fallbackMessage = "VPN connection failed.",
      error = IllegalStateException(raw, IllegalArgumentException("original cause")),
      log = { code, message, error -> deliveries += DeliveredVpnError("log", code, message, error) },
      telemetry = { code, message, error -> deliveries += DeliveredVpnError("telemetry", code, message, error) },
      reject = { code, message, error -> deliveries += DeliveredVpnError("promise", code, message, error) },
    )

    assertEquals(listOf("log", "telemetry", "promise"), deliveries.map { it.destination })
    assertEquals(setOf("VPN_CONNECT_FAILED"), deliveries.map { it.code }.toSet())
    assertEquals(3, deliveries.map { it.error }.toSet().size)
    deliveries.forEach { delivery ->
      assertEquals(null, delivery.error.cause)
      assertEquals(delivery.message, delivery.error.message)
      assertTrue(delivery.message.contains("Endpoint = 192.0.2.1:51824"))
      listOf(privateKey, presharedKey, headerKey).forEach { secret ->
        assertFalse(delivery.message.contains(secret))
        assertFalse(delivery.error.stackTraceToString().contains(secret))
      }
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

  private data class DeliveredVpnError(
    val destination: String,
    val code: String,
    val message: String,
    val error: Throwable,
  )

  private class RecordingVpnMutation(private val routedApplications: MutableList<String>) {
    var tunnelMutations = 0
    var blockerMutations = 0
    var backendMutations = 0

    fun replaceRoutedApplications(replacement: List<String>) {
      routedApplications.clear()
      routedApplications.addAll(replacement)
    }

    fun setTunnelDown() {
      tunnelMutations += 1
    }

    fun startLeakBlocker() {
      blockerMutations += 1
    }

    fun setBackendUp(@Suppress("UNUSED_PARAMETER") config: Config) {
      backendMutations += 1
    }
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
