package com.vexguard.app.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.util.Log
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
  private val recoveryScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val connectivityManager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
  private val availableUnderlyingNetworks = linkedSetOf<Network>()
  @Volatile private var transitionState: String? = null
  @Volatile private var networkRecoveryPending = false
  private var antiLeakArmed = false
  private var lastRoutedApplications: List<String> = emptyList()
  private var lastConfigText: String? = null
  private var selectedUnderlyingNetwork: Network? = null
  private val networkTransitionTracker = UnderlyingNetworkTransitionTracker<Network>()
  private val networkRecoveryRequests = Channel<Pair<Network, Network>>(Channel.CONFLATED)

  init {
    recoveryScope.launch {
      for ((previous, selected) in networkRecoveryRequests) {
        networkRecoveryPending = true
        try {
          delay(NETWORK_RECOVERY_DEBOUNCE_MS)
          recoverTunnelAfterNetworkChange(previous, selected)
        } finally {
          networkRecoveryPending = false
        }
      }
    }
    registerUnderlyingNetworkCallback()
  }

  fun needsPermission(): Boolean = VpnService.prepare(appContext) != null

  fun isNetworkRecoveryPending(): Boolean = networkRecoveryPending

  suspend fun connect(
    wgQuickConfig: String,
    antiLeakEnabled: Boolean,
    routeOnlySelectedApplications: Boolean,
    selectedApplications: List<String>,
  ): VpnConnectionState = tunnelMutex.withLock {
    transitionState = "connecting"
    try {
      withContext(Dispatchers.IO) {
        if (needsPermission()) {
          throw VpnPermissionRequiredException()
        }
        val routedApplications = if (routeOnlySelectedApplications) {
          installedSelectedApplications(selectedApplications)
        } else {
          emptyList()
        }
        lastRoutedApplications = routedApplications
        try {
          if (!VexLeakBlockerService.stopAndAwait(appContext)) {
            throw IllegalStateException("Anti-leak service did not stop before VPN connect.")
          }
          val validatedConfig = validatedConfigText(wgQuickConfig)
          val configText = if (routeOnlySelectedApplications) {
            configTextIncludingSelectedApplications(validatedConfig, routedApplications)
          } else {
            configTextExcludingSelf(validatedConfig)
          }
          val config = Config.parse(ByteArrayInputStream(configText.toByteArray(StandardCharsets.UTF_8)))
          val state = backend.setState(tunnel, Tunnel.State.UP, config)
          if (state != Tunnel.State.UP) {
            throw IllegalStateException("VPN backend did not enter the UP state.")
          }
          selectedUnderlyingNetworkSnapshot()?.let { network ->
            try {
              backend.bindTunnelSocketsToNetwork(network)
              Log.i(TAG, "New VPN sockets bound to $network immediately after tunnel start")
            } catch (error: Throwable) {
              // The TUN remains installed and therefore fail-closed. The
              // connection verifier or the next network callback will retry.
              Log.e(TAG, "Initial VPN socket bind to $network failed; retaining fail-closed TUN", error)
            }
          }
          val traffic = statsOrEmpty()
          lastConfigText = configText
          antiLeakArmed = antiLeakEnabled
          VpnConnectionState.Connected(traffic, if (antiLeakEnabled) LeakProtectionState.Armed else LeakProtectionState.Off)
        } catch (error: Throwable) {
          if (antiLeakEnabled) {
            try {
              setTunnelDown()
            } catch (_: Throwable) {
            }
            antiLeakArmed = VexLeakBlockerService.startAndAwait(appContext, routedApplications)
          }
          throw error
        }
      }
    } finally {
      transitionState = null
    }
  }

  suspend fun disconnect(releaseAntiLeak: Boolean): VpnConnectionState = tunnelMutex.withLock {
    transitionState = "disconnecting"
    try {
      withContext(Dispatchers.IO) {
        if (releaseAntiLeak) {
          // Release the separate kill-switch service before entering the native
          // backend. awgTurnOff can block inside vendor code; it must never keep
          // the user's whole phone offline after an explicit disconnect.
          VexLeakBlockerService.stopAndAwait(appContext)
          antiLeakArmed = false
        }
        setTunnelDown()
        lastConfigText = null
        if (!releaseAntiLeak) {
          antiLeakArmed = VexLeakBlockerService.startAndAwait(appContext, lastRoutedApplications)
          if (!antiLeakArmed) {
            throw IllegalStateException("Anti-leak service did not start after VPN disconnect.")
          }
        }
        VpnConnectionState.Disconnected
      }
    } finally {
      transitionState = null
    }
  }

  suspend fun status(): VpnConnectionState {
    if (!tunnelMutex.tryLock()) {
      return VpnConnectionState.Transition(
        state = transitionState ?: "connecting",
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
    val peerHandshakeEpochMillis = statistics.peers()
      .mapNotNull { statistics.peer(it)?.latestHandshakeEpochMillis() }
      .maxOrNull()
      ?: 0L
    val backendHandshakeSeconds = backend.getLastHandshake(tunnel)
    val latestHandshakeEpochMillis = VpnHandshakeVerifier.latestHandshakeEpochMillis(
      peerHandshakeEpochMillis,
      backendHandshakeSeconds,
    )
    return VpnTraffic(
      rxBytes = statistics.totalRx(),
      txBytes = statistics.totalTx(),
      latestHandshakeEpochMillis = latestHandshakeEpochMillis,
    )
  }

  private fun statsOrEmpty(): VpnTraffic {
    return try {
      stats()
    } catch (_: Throwable) {
      VpnTraffic()
    }
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

  private fun registerUnderlyingNetworkCallback() {
    val request = NetworkRequest.Builder()
      .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
      .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
      .build()
    connectivityManager.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
      override fun onAvailable(network: Network) {
        synchronized(availableUnderlyingNetworks) {
          availableUnderlyingNetworks.add(network)
          selectUnderlyingNetworkLocked()
        }
      }

      override fun onLost(network: Network) {
        synchronized(availableUnderlyingNetworks) {
          availableUnderlyingNetworks.remove(network)
          selectUnderlyingNetworkLocked()
        }
      }
    })
  }

  private fun selectUnderlyingNetworkLocked() {
    val selected = availableUnderlyingNetworks
      .mapNotNull { network ->
        connectivityManager.getNetworkCapabilities(network)?.let { capabilities -> network to capabilities }
      }
      .filterNot { (_, capabilities) -> capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) }
      .maxByOrNull { (_, capabilities) -> underlyingNetworkPreference(capabilities) }
      ?.first
    val previous = selectedUnderlyingNetwork
    if (selected == previous) {
      return
    }
    selectedUnderlyingNetwork = selected
    Log.i(TAG, "Underlying network selection changed from $previous to $selected")
    networkTransitionTracker.update(selected)?.let { (recoveryFrom, recoveryTo) ->
      scheduleNetworkRecovery(recoveryFrom, recoveryTo)
    }
  }

  private fun scheduleNetworkRecovery(previous: Network, selected: Network) {
    networkRecoveryRequests.trySend(previous to selected)
  }

  private fun selectedUnderlyingNetworkSnapshot(): Network? = synchronized(availableUnderlyingNetworks) {
    selectedUnderlyingNetwork ?: connectivityManager.allNetworks
      .mapNotNull { network ->
        connectivityManager.getNetworkCapabilities(network)?.let { capabilities -> network to capabilities }
      }
      .filter { (_, capabilities) ->
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
          capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
          !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
      }
      .maxByOrNull { (_, capabilities) -> underlyingNetworkPreference(capabilities) }
      ?.first
      ?.also { selectedUnderlyingNetwork = it }
  }

  private fun underlyingNetworkPreference(capabilities: NetworkCapabilities): Int = when {
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 3
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 2
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
    else -> 0
  }

  private suspend fun recoverTunnelAfterNetworkChange(previous: Network, selected: Network) = tunnelMutex.withLock {
    val configText = lastConfigText ?: return@withLock
    if (backend.getState(tunnel) != Tunnel.State.UP && !VexLeakBlockerService.isActive()) {
      return@withLock
    }
    transitionState = "connecting"
    Log.i(TAG, "Recovering VPN after underlying network changed from $previous to $selected")
    val preserveAntiLeak = antiLeakArmed
    try {
      if (backend.getState(tunnel) == Tunnel.State.UP && !VexLeakBlockerService.isActive()) {
        try {
          backend.bindTunnelSocketsToNetwork(selected)
          Log.i(TAG, "VPN sockets rebound to $selected without replacing the TUN interface")
        } catch (error: Throwable) {
          // Keep the existing TUN and its routes installed. That remains fail-closed,
          // and the next network callback can retry the socket bind safely.
          Log.e(TAG, "VPN socket rebind to $selected failed; retaining fail-closed TUN", error)
        }
        if (selectedUnderlyingNetwork != selected) {
          Log.i(TAG, "VPN socket rebind to $selected was superseded by $selectedUnderlyingNetwork")
          return@withLock
        }
        return@withLock
      }
      // Stop the native VPN service cleanly before the blocker takes ownership.
      // If the blocker revokes it first, Android may deliver a delayed onDestroy
      // that tears down a newly established tunnel several seconds later.
      setTunnelDown()
      if (!VexLeakBlockerService.startAndAwait(appContext, lastRoutedApplications)) {
        throw IllegalStateException("Anti-leak service did not start for network recovery.")
      }
      var recoveredConfig: Config? = null
      var recoveredConfigText: String? = null
      for (candidateText in VpnNetworkRecovery.configCandidates(configText)) {
        val candidateEndpoint = Regex("(?m)^Endpoint\\s*=\\s*(.+)$")
          .find(candidateText)?.groupValues?.getOrNull(1)?.trim().orEmpty()
        Log.i(TAG, "Trying VPN network recovery endpoint $candidateEndpoint")
        val candidateConfig = Config.parse(ByteArrayInputStream(candidateText.toByteArray(StandardCharsets.UTF_8)))
        // Android permits only one active VpnService per user. Hand ownership back
        // from the leak blocker before establishing the real tunnel, otherwise the
        // backend can handshake while the system keeps the blocker routing table.
        if (!VexLeakBlockerService.stopAndAwait(appContext)) {
          throw IllegalStateException("Anti-leak service did not stop before network recovery.")
        }
        val state = backend.setState(tunnel, Tunnel.State.UP, candidateConfig)
        val handshakeVerified = state == Tunnel.State.UP && awaitHandshake()
        Log.i(TAG, "VPN network recovery endpoint $candidateEndpoint verified=$handshakeVerified")
        if (handshakeVerified) {
          recoveredConfig = candidateConfig
          recoveredConfigText = candidateText
          break
        }
        setTunnelDown()
        if (!VexLeakBlockerService.startAndAwait(appContext, lastRoutedApplications)) {
          throw IllegalStateException("Anti-leak service did not restart between recovery attempts.")
        }
      }
      if (recoveredConfig == null || recoveredConfigText == null) {
        throw IllegalStateException("VPN handshake did not recover after network change.")
      }
      lastConfigText = recoveredConfigText
      VexLeakBlockerService.stopAndAwait(appContext)
      antiLeakArmed = preserveAntiLeak
      Log.i(TAG, "VPN recovered after underlying network change")
    } catch (error: Throwable) {
      setTunnelDown()
      antiLeakArmed = VexLeakBlockerService.startAndAwait(appContext, lastRoutedApplications)
      Log.e(TAG, "VPN network recovery failed: ${error.message}", error)
    } finally {
      transitionState = null
    }
  }

  private suspend fun awaitHandshake(): Boolean {
    repeat(NETWORK_RECOVERY_HANDSHAKE_ATTEMPTS) {
      if (statsOrEmpty().latestHandshakeEpochMillis > 0L) {
        return true
      }
      delay(NETWORK_RECOVERY_HANDSHAKE_POLL_MS)
    }
    return false
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

  private fun configTextIncludingSelectedApplications(configText: String, selectedApplications: List<String>): String {
    if (selectedApplications.isEmpty()) {
      throw IllegalArgumentException("Select at least one installed application for VPN routing.")
    }

    val lines = configText.lines().toMutableList()
    val interfaceIndex = lines.indexOfFirst { it.trim().equals("[Interface]", ignoreCase = true) }
    if (interfaceIndex < 0) {
      return configText
    }
    val nextSectionIndex = lines.indexOfFirstAfter(interfaceIndex + 1) {
      val value = it.trim()
      value.startsWith("[") && value.endsWith("]")
    }.takeIf { it >= 0 } ?: lines.size
    for (index in (nextSectionIndex - 1) downTo (interfaceIndex + 1)) {
      val key = lines[index].substringBefore("=").trim()
      if (key.equals("IncludedApplications", ignoreCase = true) ||
        key.equals("ExcludedApplications", ignoreCase = true)
      ) {
        lines.removeAt(index)
      }
    }
    lines.add(interfaceIndex + 1, "IncludedApplications = ${selectedApplications.joinToString(", ")}")
    return lines.joinToString("\n")
  }

  private fun installedSelectedApplications(selectedApplications: List<String>): List<String> {
    val packageName = appContext.packageName
    return selectedApplications
      .asSequence()
      .map(String::trim)
      .filter { it.isNotEmpty() && it != packageName }
      .distinct()
      .filter(::isApplicationInstalled)
      .toList()
  }

  private fun isApplicationInstalled(packageName: String): Boolean {
    return try {
      appContext.packageManager.getApplicationInfo(packageName, 0)
      true
    } catch (_: Throwable) {
      false
    }
  }

  companion object {
    private const val TAG = "WireGuardController"
    private const val NETWORK_RECOVERY_DEBOUNCE_MS = 750L
    private const val NETWORK_RECOVERY_HANDSHAKE_ATTEMPTS = 60
    private const val NETWORK_RECOVERY_HANDSHAKE_POLL_MS = 250L
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
