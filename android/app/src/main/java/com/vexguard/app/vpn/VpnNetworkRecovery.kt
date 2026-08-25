package com.vexguard.app.vpn

internal object VpnNetworkRecovery {
  private val endpointPattern = Regex("(?m)^Endpoint\\s*=\\s*(.+)$")

  fun configCandidates(configText: String): List<String> {
    val endpoint = endpointPattern.find(configText)?.groupValues?.getOrNull(1)?.trim()
      ?: return listOf(configText)
    val host = when {
      endpoint.startsWith("[") && endpoint.contains("]:") -> endpoint.substringAfter("[").substringBefore("]")
      endpoint.count { it == ':' } == 1 -> endpoint.substringBeforeLast(':')
      else -> return listOf(configText)
    }
    val formattedHost = if (host.contains(':')) "[$host]" else host
    // All profiles are AmneziaWG v3 since the AWG2 retirement: recovery stays
    // on the isolated AWG3 listeners and must never fall through to 51820.
    val fallbackPorts = listOf(51821, 443)
    return sequenceOf(endpoint, *fallbackPorts.map { "$formattedHost:$it" }.toTypedArray())
      .distinct()
      .map { candidate -> configText.replace(endpointPattern, "Endpoint = $candidate") }
      .toList()
  }
}
