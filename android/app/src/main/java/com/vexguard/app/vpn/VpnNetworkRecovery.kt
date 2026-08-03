package com.vexguard.app.vpn

internal object VpnNetworkRecovery {
  private val endpointPattern = Regex("(?m)^Endpoint\\s*=\\s*(.+)$")
  private val awg3HeaderProtectionPattern = Regex("(?m)^HeaderProtectionKey\\s*=\\s*\\S+")

  fun configCandidates(configText: String): List<String> {
    val endpoint = endpointPattern.find(configText)?.groupValues?.getOrNull(1)?.trim()
      ?: return listOf(configText)
    val host = when {
      endpoint.startsWith("[") && endpoint.contains("]:") -> endpoint.substringAfter("[").substringBefore("]")
      endpoint.count { it == ':' } == 1 -> endpoint.substringBeforeLast(':')
      else -> return listOf(configText)
    }
    val formattedHost = if (host.contains(':')) "[$host]" else host
    // Keep AWG3 recovery on the isolated listener. Falling through to 51820
    // would make a recovered tunnel silently rejoin the AWG2 cohort.
    val fallbackPorts = if (awg3HeaderProtectionPattern.containsMatchIn(configText)) {
      listOf(51821, 443)
    } else {
      listOf(443, 51820)
    }
    return sequenceOf(endpoint, *fallbackPorts.map { "$formattedHost:$it" }.toTypedArray())
      .distinct()
      .map { candidate -> configText.replace(endpointPattern, "Endpoint = $candidate") }
      .toList()
  }
}
