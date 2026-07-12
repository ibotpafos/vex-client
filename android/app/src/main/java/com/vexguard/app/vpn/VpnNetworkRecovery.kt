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
    return sequenceOf(endpoint, "$formattedHost:443", "$formattedHost:51820")
      .distinct()
      .map { candidate -> configText.replace(endpointPattern, "Endpoint = $candidate") }
      .toList()
  }
}
