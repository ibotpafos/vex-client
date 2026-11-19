package com.vexguard.app.vpn

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** HTTPS uses only the authenticated loopback SOCKS inbound routed to VLESS. */
internal object VlessHttpsProbe {
  fun verify(port: Int, user: String, password: String, socketChanged: (Socket?) -> Unit): Boolean {
    val deadline = System.nanoTime() + 8_000_000_000L
    fun remaining(): Int = ((deadline - System.nanoTime()) / 1_000_000L).coerceAtMost(4_000).toInt().also {
      if (it <= 0) throw IOException("VLESS verification deadline exceeded.")
    }
    val socket = Socket()
    socketChanged(socket)
    try {
      socket.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), remaining())
      socket.soTimeout = remaining()
      negotiate(DataInputStream(socket.getInputStream()), DataOutputStream(socket.getOutputStream()), user, password)
      socket.soTimeout = remaining()
      val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
        .createSocket(socket, VlessRuntimeConfig.HEALTH_HOST, 443, true) as SSLSocket
      tls.use {
        socketChanged(tls)
        tls.soTimeout = remaining()
        tls.sslParameters = tls.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
        tls.startHandshake()
        tls.soTimeout = remaining()
        tls.getOutputStream().write(("HEAD ${VlessRuntimeConfig.HEALTH_PATH} HTTP/1.1\r\n" +
          "Host: ${VlessRuntimeConfig.HEALTH_HOST}\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n").toByteArray(Charsets.US_ASCII))
        tls.getOutputStream().flush()
        readFinalResponse(tls.getInputStream()) {
          tls.soTimeout = remaining()
        }
        // A complete authenticated HTTPS response proves the transport even
        // when the origin rejects, rate-limits or cannot serve this request.
        return true
      }
    } finally {
      runCatching { socket.close() }
      socketChanged(null)
    }
  }

  /** Read only bounded HTTP/1.x status/header framing; never consume a body. */
  internal fun readFinalResponse(input: InputStream, beforeRead: () -> Unit = {}): Int {
    var bytes = 0
    var headers = 0
    fun next(): Int {
      if (++bytes > 16_384) throw IOException("VLESS verification headers are too large.")
      beforeRead()
      return input.read().also { if (it < 0) throw IOException("VLESS verification response ended early.") }
    }
    fun line(limit: Int): String {
      val result = StringBuilder()
      while (true) {
        val character = next()
        if (character == 13) {
          if (next() != 10) throw IOException("VLESS verification response framing is invalid.")
          return result.toString()
        }
        if (character == 10 || result.length >= limit) throw IOException("VLESS verification response framing is invalid.")
        result.append(character.toChar())
      }
    }
    fun fieldCharacter(character: Char) = character == '\t' || character.code >= 32 && character.code != 127
    fun nameCharacter(character: Char) = character in 'a'..'z' || character in 'A'..'Z' || character in '0'..'9'
      || character in "!#$%&'*+-.^_`|~"
    // Permit at most four complete informational responses before the final
    // response. Switching protocols is not an HTTP final response for this probe.
    repeat(5) { block ->
      val status = line(1024)
      if (!(status.startsWith("HTTP/1.0 ") || status.startsWith("HTTP/1.1 "))
        || status.length < 13 || status[12] != ' ' || status.substring(9, 12).any { it !in '0'..'9' }
        || status.drop(13).any { !fieldCharacter(it) }) throw IOException("VLESS verification status is invalid.")
      val code = status.substring(9, 12).toInt()
      if (code !in 100..599 || code == 101 || code < 200 && block == 4) throw IOException("VLESS verification status is invalid.")
      while (true) {
        val header = line(4096)
        if (header.isEmpty()) break
        if (++headers > 100) throw IOException("VLESS verification has too many headers.")
        val colon = header.indexOf(':')
        if (colon < 1 || header.take(colon).any { !nameCharacter(it) }
          || header.drop(colon + 1).any { !fieldCharacter(it) }) throw IOException("VLESS verification header is invalid.")
      }
      if (code >= 200) return code
    }
    throw IOException("VLESS verification final response is missing.")
  }

  // RFC 1928/1929 local proxy framing only. All VLESS/XHTTP/TLS transport
  // implementation remains in the pinned, unmodified upstream core.
  internal fun negotiate(input: DataInputStream, output: DataOutputStream, user: String, password: String) {
    val username = user.toByteArray(Charsets.UTF_8)
    val secret = password.toByteArray(Charsets.UTF_8)
    require(username.size in 1..255 && secret.size in 1..255)
    output.write(byteArrayOf(5, 1, 2))
    output.flush()
    if (input.readUnsignedByte() != 5 || input.readUnsignedByte() != 2) throw IOException("VLESS local proxy authentication is unavailable.")
    output.writeByte(1)
    output.writeByte(username.size)
    output.write(username)
    output.writeByte(secret.size)
    output.write(secret)
    output.flush()
    if (input.readUnsignedByte() != 1 || input.readUnsignedByte() != 0) throw IOException("VLESS local proxy authentication failed.")
    val host = VlessRuntimeConfig.HEALTH_HOST.toByteArray(Charsets.US_ASCII)
    output.write(byteArrayOf(5, 1, 0, 3))
    output.writeByte(host.size)
    output.write(host)
    output.writeShort(443)
    output.flush()
    if (input.readUnsignedByte() != 5 || input.readUnsignedByte() != 0 || input.readUnsignedByte() != 0) {
      throw IOException("VLESS local proxy could not open the verification connection.")
    }
    val addressBytes = when (input.readUnsignedByte()) {
      1 -> 4
      4 -> 16
      3 -> input.readUnsignedByte()
      else -> throw IOException("VLESS local proxy response is invalid.")
    }
    input.readFully(ByteArray(addressBytes + 2))
  }
}
