package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class VlessHttpsProbeTest {
  private fun response(value: String) = ByteArrayInputStream(value.toByteArray(Charsets.ISO_8859_1))
  private fun reject(value: String) {
    try {
      VlessHttpsProbe.readFinalResponse(response(value))
      fail("An incomplete or malformed HTTP response confirmed the VPN")
    } catch (_: IOException) { }
  }

  @Test fun finalHttpBusinessStatusDoesNotChangeTransportProofOrConsumeTheBody() {
    for (version in listOf("1.0", "1.1")) {
      for (code in listOf(200, 204, 301, 401, 405, 429, 503, 599)) {
        val input = response("HTTP/$version $code Status\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\nbody")
        assertEquals(code, VlessHttpsProbe.readFinalResponse(input))
        assertEquals(4, input.available())
        assertEquals('b'.code, input.read())
      }
    }
    assertEquals(204, VlessHttpsProbe.readFinalResponse(response("HTTP/1.1 204 \r\n\r\n")))
  }

  @Test fun completeStatusAndHeaderTerminatorAreRequired() {
    for (value in listOf("", "HTTP/1.1 200 OK", "HTTP/1.1 200 OK\r", "HTTP/1.1 200 OK\r\n",
      "HTTP/1.1 401 Unauthorized\r\nRetry-After: 5", "HTTP/1.1 429 Limited\r\nRetry-After: 5\r\n\r")) reject(value)
  }

  @Test fun malformedStatusCannotConfirmTheTransport() {
    for (status in listOf("HTTP/2 200 OK", "HTTP/1.2 200 OK", "HTTP/1.1 600 Unknown", "HTTP/1.1 099 Unknown",
      "HTTP/1.1 20 OK", "HTTP/1.1 2x0 OK", "HTTP/1.1 200", "HTTP/1.1 200OK", "HTTP/1.1 200 Bad\u0001Reason")) {
      reject("$status\r\n\r\n")
    }
  }

  @Test fun malformedHeadersAndBareLineFeedsCannotConfirmTheTransport() {
    for (header in listOf("Missing-Colon", ": empty-name", "Bad Name: value", " Folded: value", "Bad: value\u0000", "Bad: value\u007f")) {
      reject("HTTP/1.1 503 Unavailable\r\n$header\r\n\r\n")
    }
    reject("HTTP/1.1 200 OK\n\n")
    reject("HTTP/1.1 200 OK\r\nName: value\n\r\n")
    reject("HTTP/1.1 200 OK\rX\r\n")
  }

  @Test fun statusLineHeaderLineTotalBytesAndHeaderCountAreBounded() {
    reject("HTTP/1.1 200 " + "x".repeat(1024) + "\r\n\r\n")
    reject("HTTP/1.1 200 OK\r\nLong: " + "x".repeat(4096) + "\r\n\r\n")
    reject("HTTP/1.1 200 OK\r\n" + ("Long: " + "x".repeat(1000) + "\r\n").repeat(17) + "\r\n")
    reject("HTTP/1.1 200 OK\r\n" + "X: y\r\n".repeat(101) + "\r\n")
  }

  @Test fun informationalResponsesNeedABoundedFinalResponseAndCannotSwitchProtocols() {
    val information = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n"
    assertEquals(204, VlessHttpsProbe.readFinalResponse(response(information + "HTTP/1.1 204 No Content\r\n\r\n")))
    reject(information)
    reject("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
    reject(information.repeat(5) + "HTTP/1.1 200 OK\r\n\r\n")
  }

  @Test fun everyStatusAndHeaderByteRemainsUnderTheCallerDeadline() {
    var reads = 0
    try {
      VlessHttpsProbe.readFinalResponse(response("HTTP/1.1 200 OK\r\nX: slow\r\n\r\n")) {
        if (++reads == 21) throw IOException("Synthetic deadline exceeded")
      }
      fail("A deadline-expired partial response confirmed the VPN")
    } catch (_: IOException) { }
    assertEquals(21, reads)
  }

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
