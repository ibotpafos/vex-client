package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class VlessHttpsProbeTest {
  @Test fun localProxyRequiresAuthenticationAndAnUnresolvedOwnedDestination() {
    val response = byteArrayOf(5, 2, 1, 0, 5, 0, 0, 1, 127, 0, 0, 1, 0, 1)
    val bytes = ByteArrayOutputStream()
    VlessHttpsProbe.negotiate(DataInputStream(ByteArrayInputStream(response)), DataOutputStream(bytes), "u", "p")
    val request = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
    assertEquals(listOf(5, 1, 2, 1, 1, 'u'.code, 1, 'p'.code, 5, 1, 0, 3), (0 until 12).map { request.readUnsignedByte() })
    val host = ByteArray(request.readUnsignedByte()).also(request::readFully).toString(Charsets.US_ASCII)
    assertEquals(VlessRuntimeConfig.HEALTH_HOST, host)
    assertEquals(443, request.readUnsignedShort())
  }

  @Test fun anonymousOrFailedLocalProxyCannotConfirmVpnHealth() {
    for (response in listOf(byteArrayOf(5, 0), byteArrayOf(5, 2, 1, 1), byteArrayOf(5, 2, 1, 0, 5, 5, 0, 1))) {
      try {
        VlessHttpsProbe.negotiate(DataInputStream(ByteArrayInputStream(response)), DataOutputStream(ByteArrayOutputStream()), "u", "p")
        fail("A failed proxy negotiation was accepted")
      } catch (_: IOException) { }
    }
  }
}
