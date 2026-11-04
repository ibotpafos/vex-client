package com.vexguard.app.vpn

/** Owner control traffic must remain available to renew a failed VPN profile. */
internal object VlessApplicationPolicy {
  data class Selection(val allowed: List<String>, val excluded: List<String>)

  fun admit(packages: List<String>, selectedOnly: Boolean, ownerPackage: String, installed: (String) -> Boolean): Selection {
    if (!selectedOnly) return Selection(emptyList(), listOf(ownerPackage))
    require(packages.size <= 256) { "VLESS application selection is invalid." }
    val effective = packages.distinct().filter { it != ownerPackage }
    require(effective.isNotEmpty()) { "Select an installed application other than VEX for VLESS." }
    effective.forEach { name ->
      require(name.length <= 255 && name.matches(Regex("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+"))) { "VLESS application selection is invalid." }
      require(installed(name)) { "A selected VLESS application is not installed." }
    }
    return Selection(effective, emptyList())
  }
}
