package com.vexguard.app.vpn

import org.amnezia.awg.config.Config

/**
 * The sole admission and mutation boundary for VPN profile transitions.
 * Raw input is normalized, routing transforms are applied, and the official
 * parser validates the completed profile before any supplied mutation runs.
 */
internal object VpnConfigActivation {
  fun parse(configText: String): Config = AwgConfigSafety.parseForActivation(configText)

  fun prepare(
    rawConfigText: String,
    routeOnlySelectedApplications: Boolean,
    selectedApplications: List<String>,
    appPackageName: String,
  ): Admission {
    val normalized = normalizeRawConfig(rawConfigText)
    val configText = if (routeOnlySelectedApplications) {
      configTextIncludingSelectedApplications(normalized, selectedApplications)
    } else {
      configTextExcludingSelf(normalized, appPackageName)
    }
    return Admission(configText, parse(configText))
  }

  fun parseRecoveryCandidates(configText: String): List<ValidatedCandidate> =
    VpnNetworkRecovery.configCandidates(configText).map { candidateText ->
      ValidatedCandidate(candidateText, parse(candidateText))
    }

  /** Validation is intentionally outside the mutation failure handler. */
  suspend fun <T> orchestrate(
    rawConfigText: String,
    routeOnlySelectedApplications: Boolean,
    selectedApplications: List<String>,
    appPackageName: String,
    mutate: suspend (Admission) -> T,
    onMutationFailure: suspend (Throwable) -> Unit,
  ): T {
    val admission = prepare(
      rawConfigText,
      routeOnlySelectedApplications,
      selectedApplications,
      appPackageName,
    )
    return try {
      mutate(admission)
    } catch (error: Throwable) {
      onMutationFailure(error)
      throw error
    }
  }

  private fun normalizeRawConfig(rawConfigText: String): String {
    val value = rawConfigText.trim()
    if (value.isEmpty()) {
      throw AwgConfigValidationException("VPN config is empty.")
    }
    if (!value.contains("[Interface]") || !value.contains("[Peer]")) {
      throw AwgConfigValidationException("VPN config is invalid or incomplete.")
    }
    return value
  }

  private fun configTextExcludingSelf(configText: String, appPackageName: String): String {
    val packageName = appPackageName.takeIf { it.isNotBlank() } ?: return configText
    val lines = configText.lines().toMutableList()
    val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
    if (interfaceIndex < 0) return configText
    val nextSectionIndex = nextSectionIndex(lines, interfaceIndex)
    val hasIncludedApplications = (interfaceIndex + 1 until nextSectionIndex).any {
      lines[it].substringBefore("=").trim().equals("IncludedApplications", ignoreCase = true)
    }
    if (hasIncludedApplications) return configText
    val excludedIndex = (interfaceIndex + 1 until nextSectionIndex).firstOrNull {
      lines[it].substringBefore("=").trim().equals("ExcludedApplications", ignoreCase = true)
    }
    if (excludedIndex != null) {
      val prefix = lines[excludedIndex].substringBefore("=")
      val apps = lines[excludedIndex].substringAfter("=", "")
        .split(',').map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
      if (apps.none { it == packageName }) apps.add(packageName)
      lines[excludedIndex] = "${prefix.trim()} = ${apps.joinToString(", ")}"
      return lines.joinToString("\n")
    }
    lines.add(interfaceIndex + 1, "ExcludedApplications = $packageName")
    return lines.joinToString("\n")
  }

  private fun configTextIncludingSelectedApplications(configText: String, selectedApplications: List<String>): String {
    if (selectedApplications.isEmpty()) {
      throw AwgConfigValidationException("Select at least one installed application for VPN routing.")
    }
    val lines = configText.lines().toMutableList()
    val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
    if (interfaceIndex < 0) return configText
    val nextSectionIndex = nextSectionIndex(lines, interfaceIndex)
    for (index in (nextSectionIndex - 1) downTo (interfaceIndex + 1)) {
      val key = lines[index].substringBefore("=").trim()
      if (key.equals("IncludedApplications", ignoreCase = true) || key.equals("ExcludedApplications", ignoreCase = true)) {
        lines.removeAt(index)
      }
    }
    lines.add(interfaceIndex + 1, "IncludedApplications = ${selectedApplications.joinToString(", ")}")
    return lines.joinToString("\n")
  }

  private fun nextSectionIndex(lines: List<String>, interfaceIndex: Int): Int =
    lines.drop(interfaceIndex + 1).indexOfFirst {
      val value = it.trim()
      value.startsWith("[") && value.endsWith("]")
    }.let { relative -> if (relative < 0) lines.size else interfaceIndex + 1 + relative }

  data class Admission(
    val text: String,
    val config: Config,
  )

  data class ValidatedCandidate(
    val text: String,
    val config: Config,
  )
}
