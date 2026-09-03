package com.vexguard.app.vpn

internal object VpnNetworkRecovery {
  /**
   * Network recovery may retry only endpoints explicitly present in the supplied profile.
   * Alternate listeners require an explicit profile contract; never synthesize ports here.
   */
  fun configCandidates(configText: String): List<String> = listOf(configText)
}
