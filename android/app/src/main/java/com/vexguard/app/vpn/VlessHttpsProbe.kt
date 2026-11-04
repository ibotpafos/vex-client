package com.vexguard.app.vpn

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
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
        tls.getOutputStream().write(("GET ${VlessRuntimeConfig.HEALTH_PATH} HTTP/1.1\r\n" +
          "Host: ${VlessRuntimeConfig.HEALTH_HOST}\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n").toByteArray(Charsets.US_ASCII))
        tls.getOutputStream().flush()
        val input = tls.getInputStream()
        val status = StringBuilder()
        while (status.length < 1024) {
          tls.soTimeout = remaining()
          val next = input.read()
          if (next < 0) throw IOException("VLESS verification response ended early.")
          if (next == 10) break
          if (next != 13) status.append(next.toChar())
        }
        return status.toString().matches(Regex("HTTP/1\\.[01] 200(?: .*)?"))
      }
    } finally {
      runCatching { socket.close() }
      socketChanged(null)
    }
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
