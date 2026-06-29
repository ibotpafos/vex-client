package com.vexguard.app.vpn

import android.content.Context
import android.net.VpnService
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.config.Config

class WireGuardController(context: Context) {
  private val appContext = context.applicationContext
  private val backend = GoBackend(appContext)
  private val tunnel = VexTunnel()
  private val tunnelMutex = Mutex()
  private var antiLeakArmed = false

  fun needsPermission(): Boolean = VpnService.prepare(appContext) != null

  suspend fun connect(wgQuickConfig: String, antiLeakEnabled: Boolean): VpnConnectionState = tunnelMutex.withLock {
    withContext(Dispatchers.IO) {
      if (needsPermission()) {
        throw VpnPermissionRequiredException()
      }
      val shouldBlockOnFailure = antiLeakEnabled && (antiLeakArmed || backend.getState(tunnel) == Tunnel.State.UP)
      try {
        VexLeakBlockerService.stop(appContext)
        val configText = configTextExcludingSelf(validatedConfigText(wgQuickConfig))
        val config = Config.parse(ByteArrayInputStream(configText.toByteArray(StandardCharsets.UTF_8)))
        resetTunnelBeforeApplyingConfig()
        val state = backend.setState(tunnel, Tunnel.State.UP, config)
        if (state != Tunnel.State.UP) {
          return@withContext state.toConnectionState(statsOrEmpty(), antiLeakEnabled)
        }
        val traffic = statsOrEmpty()
        antiLeakArmed = antiLeakEnabled
        VpnConnectionState.Connected(traffic, if (antiLeakEnabled) LeakProtectionState.Armed else LeakProtectionState.Off)
      } catch (error: Throwable) {
        if (shouldBlockOnFailure) {
          setTunnelDown()
          VexLeakBlockerService.start(appContext)
          antiLeakArmed = true
        }
        throw error
      }
    }
  }

  suspend fun disconnect(releaseAntiLeak: Boolean): VpnConnectionState = tunnelMutex.withLock {
    withContext(Dispatchers.IO) {
      setTunnelDown()
      if (releaseAntiLeak) {
        VexLeakBlockerService.stop(appContext)
        antiLeakArmed = false
      }
      VpnConnectionState.Disconnected
    }
  }

  suspend fun status(): VpnConnectionState {
    if (!tunnelMutex.tryLock()) {
      return VpnConnectionState.Transition(
        state = "connecting",
        leakProtection = if (antiLeakArmed) LeakProtectionState.Armed else LeakProtectionState.Off,
      )
    }
    return try {
      withContext(Dispatchers.IO) {
      if (VexLeakBlockerService.isActive()) {
        return@withContext VpnConnectionState.Blocking
      }
      backend.getState(tunnel).toConnectionState(statsOrEmpty(), antiLeakArmed)
      }
    } finally {
      tunnelMutex.unlock()
    }
  }

  suspend fun measureEndpointLatency(endpoint: String): Double? = withContext(Dispatchers.IO) {
    val host = endpointHost(endpoint) ?: return@withContext null
    val process = ProcessBuilder("ping", "-c", "1", "-W", "1", host)
      .redirectErrorStream(true)
      .start()
    val output = process.inputStream.bufferedReader().use { it.readText() }
    val exitCode = process.waitFor()
    if (exitCode != 0) {
      return@withContext null
    }
    parsePingLatencyMs(output)
  }

  private fun stats(): VpnTraffic {
    val statistics = backend.getStatistics(tunnel)
    return VpnTraffic(
      rxBytes = statistics.totalRx(),
      txBytes = statistics.totalTx(),
      latestHandshakeEpochMillis = latestHandshakeEpochMillis(),
    )
  }

  private fun statsOrEmpty(): VpnTraffic {
    return try {
      stats()
    } catch (_: Throwable) {
      VpnTraffic()
    }
  }

  private fun latestHandshakeEpochMillis(): Long {
    val latestHandshakeSeconds = backend.getLastHandshake(tunnel)
    if (latestHandshakeSeconds <= 0L) {
      return 0L
    }
    return latestHandshakeSeconds * 1000L
  }

  private suspend fun resetTunnelBeforeApplyingConfig() {
    if (backend.getState(tunnel) == Tunnel.State.DOWN) {
      return
    }
    setTunnelDown()
    kotlinx.coroutines.delay(TUNNEL_RESTART_SETTLE_MS)
  }

  private fun setTunnelDown() {
    try {
      backend.setState(tunnel, Tunnel.State.DOWN, null)
    } catch (error: Throwable) {
      if (backend.getState(tunnel) != Tunnel.State.DOWN) {
        throw error
      }
    }
  }

  private fun validatedConfigText(wgQuickConfig: String): String {
    val value = wgQuickConfig.trim()
    if (value.isEmpty()) {
      throw IllegalArgumentException("VPN config is empty.")
    }
    if (!value.contains("[Interface]") || !value.contains("[Peer]")) {
      throw IllegalArgumentException("VPN config is invalid or incomplete.")
    }
    return value
  }

  private fun configTextExcludingSelf(configText: String): String {
    val packageName = appContext.packageName.takeIf { it.isNotBlank() } ?: return configText
    val lines = configText.lines().toMutableList()
    val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
    if (interfaceIndex < 0) {
      return configText
    }
    val nextSectionIndex = lines.indexOfFirstAfter(interfaceIndex + 1) {
      val value = it.trim()
      value.startsWith("[") && value.endsWith("]")
    }.takeIf { it >= 0 } ?: lines.size
    val hasIncludedApplications = (interfaceIndex + 1 until nextSectionIndex).any {
      lines[it].substringBefore("=").trim().equals("IncludedApplications", ignoreCase = true)
    }
    if (hasIncludedApplications) {
      return configText
    }
    val excludedIndex = (interfaceIndex + 1 until nextSectionIndex).firstOrNull {
      lines[it].substringBefore("=").trim().equals("ExcludedApplications", ignoreCase = true)
    }
    if (excludedIndex != null) {
      val prefix = lines[excludedIndex].substringBefore("=")
      val apps = lines[excludedIndex]
        .substringAfter("=", "")
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .toMutableList()
      if (apps.none { it == packageName }) {
        apps.add(packageName)
      }
      lines[excludedIndex] = "${prefix.trim()} = ${apps.joinToString(", ")}"
      return lines.joinToString("\n")
    }
    lines.add(interfaceIndex + 1, "ExcludedApplications = $packageName")
    return lines.joinToString("\n")
  }

  private fun Tunnel.State.toConnectionState(traffic: VpnTraffic, antiLeakEnabled: Boolean): VpnConnectionState {
    return when (this) {
      Tunnel.State.UP -> VpnConnectionState.Connected(traffic, if (antiLeakEnabled) LeakProtectionState.Armed else LeakProtectionState.Off)
      Tunnel.State.DOWN -> VpnConnectionState.Disconnected
      Tunnel.State.TOGGLE -> VpnConnectionState.Disconnected
    }
  }

  private fun endpointHost(endpoint: String): String? {
    val value = endpoint.trim()
    if (value.isEmpty()) {
      return null
    }
    if (value.startsWith("[") && value.contains("]")) {
      return value.substringAfter("[").substringBefore("]").trim().ifEmpty { null }
    }
    val lastColon = value.lastIndexOf(':')
    if (lastColon > 0 && value.indexOf(':') == lastColon) {
      return value.substring(0, lastColon).trim().ifEmpty { null }
    }
    return value
  }

  private fun parsePingLatencyMs(output: String): Double? {
    val match = Regex("""time[=<]([0-9.]+)""").find(output) ?: return null
    return match.groupValues.getOrNull(1)?.toDoubleOrNull()
  }

  companion object {
    private const val TUNNEL_RESTART_SETTLE_MS = 500L
  }
}

private inline fun <T> List<T>.indexOfFirstAfter(startIndex: Int, predicate: (T) -> Boolean): Int {
  for (index in startIndex until size) {
    if (predicate(this[index])) {
      return index
    }
  }
  return -1
}

sealed interface VpnConnectionState {
  data object Disconnected : VpnConnectionState
  data object Blocking : VpnConnectionState
  data class Transition(val state: String, val leakProtection: LeakProtectionState) : VpnConnectionState
  data class Connected(val traffic: VpnTraffic, val leakProtection: LeakProtectionState) : VpnConnectionState
}

enum class LeakProtectionState(val wireValue: String) {
  Off("off"),
  Armed("armed"),
}

data class VpnTraffic(
  val rxBytes: Long = 0,
  val txBytes: Long = 0,
  val latestHandshakeEpochMillis: Long = 0,
)

class VpnPermissionRequiredException : Exception("Android VPN permission is required.")
