package com.vexguard.app.vpn

/** Orders engine commands and persists AWG intent before asynchronous work. */
internal class VpnEngineRevision(
  initialAwgWanted: Boolean?,
  private val persistAwgWanted: (Boolean) -> Unit,
) {
  private var revision = 0L
  private var wanted = initialAwgWanted

  @Synchronized
  fun next(awgWanted: Boolean? = null): Long {
    if (awgWanted != null) save(awgWanted)
    revision += 1
    return revision
  }

  @Synchronized
  fun get(): Long = revision

  @Synchronized
  fun awgWanted(): Boolean? = wanted

  @Synchronized
  fun setAwgWanted(operation: Long, value: Boolean): Boolean {
    if (operation != revision) return false
    save(value)
    return true
  }

  private fun save(value: Boolean) {
    persistAwgWanted(value)
    wanted = value
  }
}
