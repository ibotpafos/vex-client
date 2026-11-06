package com.vexguard.app.vpn

import java.net.URI
import java.util.Locale

/** Only first-party API recovery may use a socket outside captured VPN routing. */
internal object ApiRecoveryPolicy {
  const val MAX_BYTES = 2 * 1024 * 1024
  const val MAX_CALLS = 8
  private val hosts = setOf("vexguard.app", "www.vexguard.app", "api.vexguard.app")

  fun acceptsUrl(raw: String): Boolean = runCatching {
    if (raw.length > 4096) return@runCatching false
    val uri = URI(raw)
    uri.scheme.equals("https", ignoreCase = true) &&
      uri.host?.lowercase(Locale.ROOT) in hosts && uri.port in setOf(-1, 443) &&
      uri.rawUserInfo == null && uri.rawFragment == null &&
      uri.normalize().path.startsWith("/v1/") &&
      uri.path.split('/').none { it == "." || it == ".." }
  }.getOrDefault(false)

  fun acceptsHeader(name: String, value: String): Boolean =
    name.matches(Regex("[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}")) &&
      name.lowercase(Locale.ROOT) !in setOf("host", "connection", "content-length", "proxy-authorization", "proxy-connection", "transfer-encoding", "upgrade") &&
      value.length <= 16_384 && value.none { it.code < 0x20 || it.code == 0x7f }

  fun acceptsRequestId(id: String): Boolean = id.matches(Regex("api-[0-9]{1,16}-[0-9]{1,12}"))
}
