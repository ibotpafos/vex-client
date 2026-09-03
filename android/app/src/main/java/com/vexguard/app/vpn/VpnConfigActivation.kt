package com.vexguard.app.vpn

import org.amnezia.awg.config.Config

/**
 * The sole admission gate for any VPN state transition using an AWG profile.
 * Code inside [afterValidation] is allowed to mutate the tunnel, leak blocker,
 * backend, and retained routing state only after the complete profile parses.
 */
internal object VpnConfigActivation {
  fun parse(configText: String): Config = AwgConfigSafety.parseForActivation(configText)

  fun parseRecoveryCandidates(configText: String): List<ValidatedCandidate> =
    VpnNetworkRecovery.configCandidates(configText).map { candidateText ->
      ValidatedCandidate(candidateText, parse(candidateText))
    }

  suspend fun <T> afterValidation(configText: String, mutate: suspend (Config) -> T): T =
    mutate(parse(configText))

  data class ValidatedCandidate(
    val text: String,
    val config: Config,
  )
}
