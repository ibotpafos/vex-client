package com.vexguard.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import libXray.DialerController
import libXray.LibXray
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/** The only process permitted to load libXray's Go runtime. No RN/AWG classes. */
class VlessVpnService : VpnService() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val operations = Mutex()
  private val verification = VlessVerificationState()
  private lateinit var connectivity: ConnectivityManager
  private var tunnel: ParcelFileDescriptor? = null
  private var outbound: JSONObject? = null
  private var healthJob: Job? = null
  private var recoveryJob: Job? = null
  @Volatile private var enabled = false
  @Volatile private var destroyed = false
  private var antiLeak = true
  private var coreRunning = false
  private var coreTouched = false
  @Volatile private var coreNetworkRevision = -1L
  private var socksPort = 0
  private var socksUser = ""
  private var socksPassword = ""
  @Volatile private var selectedNetwork: Network? = null
  @Volatile private var networkRevision = 0L
  private val proofSocketLock = Any()
  private var proofSocket: Socket? = null
  private var proofOwner: VlessVerificationState.Lease? = null
  private var selectedDns = ""
  private var recoveryFailures = 0
  private val commandRevision = AtomicLong()

  private val controller = object : DialerController {
    override fun protectFd(fd: Long): Boolean {
      if (fd < 0 || fd > Int.MAX_VALUE) return false
      val network = selectedNetwork ?: return false
      val generation = networkRevision
      return runCatching {
        val caps = connectivity.getNetworkCapabilities(network) ?: return@runCatching false
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
          || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
          || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return@runCatching false
        if (!protect(fd.toInt())) return@runCatching false
        // FD numbers are local to this process. Borrow a duplicate solely for
        // bindSocket; never pass an integer FD across Binder or close Go's FD.
        ParcelFileDescriptor.fromFd(fd.toInt()).use { network.bindSocket(it.fileDescriptor) }
        network == selectedNetwork && generation == networkRevision
      }.getOrDefault(false)
    }
  }

  private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
    if (message.sendingUid != android.os.Process.myUid()) return@Handler true
    if (message.what == VlessVpnIpc.READ_STATUS) {
      reply(message, status())
    } else {
      // Handler recycles its Message on return. The coroutine owns a copy,
      // including its Binder reply endpoint and credential-bearing Bundle.
      val request = Message.obtain(message)
      val order = commandRevision.incrementAndGet()
      if (request.what == VlessVpnIpc.DISCONNECT) {
        // Supersede startup immediately; a pending JNI operation is not a
        // license to accept a late connection after a user disconnects.
        enabled = false
        verification.stop(retainCapture = !request.data.getBoolean(VlessVpnIpc.RELEASE, true))
        cancelProof()
      }
      scope.launch {
        operations.withLock {
          try {
            check(order == commandRevision.get() && !destroyed) { "VLESS operation was superseded." }
            when (request.what) {
              VlessVpnIpc.CONNECT -> connect(request.data, order)
              VlessVpnIpc.DISCONNECT -> disconnect(request.data.getBoolean(VlessVpnIpc.RELEASE, true))
              else -> throw IllegalArgumentException("Unsupported VLESS operation.")
            }
            reply(request, status())
          } catch (_: Throwable) {
            // libXray error strings/configuration can contain credentials.
            // They never cross Binder, logcat, crash reporting or analytics.
            reply(request, null, "native_operation_failed")
          } finally { request.recycle() }
        }
      }
    }
    true
  })

  private val networkCallback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) = refreshNetwork()
    override fun onLost(network: Network) = refreshNetwork()
    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = refreshNetwork()
    override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = refreshNetwork()
  }

  override fun onCreate() {
    super.onCreate()
    check(VlessVpnProcess.isVless(this)) { "VLESS core requires its dedicated process." }
    connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    startForeground(NOTIFICATION_ID, notification())
    connectivity.registerNetworkCallback(NetworkRequest.Builder()
      .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
      .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), networkCallback)
    refreshNetwork()
  }

  override fun onBind(intent: Intent): IBinder? =
    if (intent.action == VlessVpnIpc.ACTION) messenger.binder else super.onBind(intent)

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

  private fun connect(data: Bundle, order: Long) {
    check(!destroyed) { "VLESS service stopped." }
    val admitted = VlessRuntimeConfig.admit(data.getString(VlessVpnIpc.CONFIG).orEmpty(), data.getString(VlessVpnIpc.ROUTING).orEmpty())
    val selectedOnly = data.getBoolean(VlessVpnIpc.SELECTED_ONLY)
    val applications = VlessApplicationSelection.admit(this, data.getStringArrayList(VlessVpnIpc.PACKAGES).orEmpty(), selectedOnly)
    require(prepare(this) == null) { "Android VPN permission is required." }
    check(order == commandRevision.get()) { "VLESS operation was superseded." }
    // All known policy/transport/app checks above precede native mutation.
    recoveryJob?.cancel()
    recoveryJob = null
    enabled = false
    cancelProof()
    stopCore()
    check(order == commandRevision.get() && !destroyed) { "VLESS operation was superseded." }
    antiLeak = data.getBoolean(VlessVpnIpc.ANTILEAK, true)
    outbound = admitted
    verification.begin(antiLeak)
    val previousTunnel = tunnel
    try {
      val builder = Builder().setSession("VEX").setMtu(VlessRuntimeConfig.MTU)
        .addAddress(VlessRuntimeConfig.TUN_ADDRESS, 30).addAddress(VlessRuntimeConfig.TUN_IPV6, 126)
        .addRoute("0.0.0.0", 0).addRoute("::", 0).addDnsServer(VlessRuntimeConfig.TUN_DNS).setBlocking(false)
      applications.allowed.forEach { builder.addAllowedApplication(it) }
      applications.excluded.forEach { builder.addDisallowedApplication(it) }
      val current = builder.establish() ?: throw IllegalStateException("VLESS capture could not be established.")
      tunnel = current
      runCatching { previousTunnel?.close() }
      verification.setCapture(true)
      check(order == commandRevision.get() && !destroyed) { "VLESS operation was superseded." }
      enabled = true
      recoveryFailures = 0
      refreshNetwork(schedule = false)
      restartCore(order)
    } catch (_: Throwable) {
      verification.invalidate("data_plane_failed")
      // Keep whichever TUN is still owned; shutdown of an unverified core is
      // never permission to restore a direct route when protection is enabled.
      if (!antiLeak) closeTunnel()
      if (enabled && antiLeak && tunnel != null && order == commandRevision.get() && !destroyed) {
        // Return this connection's pending identity while the retained capture
        // protects selected apps and bounded native recovery retries startup.
        scheduleRecovery(nextRecoveryDelay(), forceRestart = true)
        return
      }
      throw IllegalStateException("VLESS connection could not be started.")
    }
  }

  private fun restartCore(order: Long = commandRevision.get()) {
    cancelProof()
    stopCore()
    val network = selectedNetwork
    val physicalRevision = networkRevision
    verification.invalidate(if (network == null) "network_unavailable" else "probe_pending")
    if (!enabled || destroyed || network == null || order != commandRevision.get()) return
    val current = tunnel ?: throw IllegalStateException("VLESS capture is unavailable.")
    val server = outbound ?: throw IllegalStateException("VLESS profile is unavailable.")
    try {
      setUnderlyingNetworks(arrayOf(network))
      coreTouched = true
      LibXray.registerDialerController(controller)
      LibXray.registerListenerController(controller)
      LibXray.setDNS(controller, dnsEndpoint(network))
      socksPort = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
      socksUser = UUID.randomUUID().toString()
      socksPassword = UUID.randomUUID().toString()
      // Upstream's Android TUN duplicates its input on success. Lend it an
      // additional duplicate so even its SetNonblock error cleanup cannot
      // close the service-owned fail-closed descriptor.
      ParcelFileDescriptor.dup(current.fileDescriptor).use { input ->
        invoke("runXray", VlessRuntimeConfig.build(server, input.fd, socksPort, socksUser, socksPassword))
      }
      coreRunning = true
      coreNetworkRevision = physicalRevision
      if (!enabled || destroyed || order != commandRevision.get()) {
        stopCore()
        return
      }
      val ready = synchronized(this) {
        if (physicalRevision == networkRevision && network == selectedNetwork) {
          verification.setCoreReady(true)
          true
        } else false
      }
      if (!ready) {
        stopCore()
        scheduleRecovery(750, forceRestart = true)
        return
      }
      startHealthChecks()
    } catch (_: Throwable) {
      stopCore()
      verification.invalidate("data_plane_failed")
      if (!antiLeak) closeTunnel()
      throw IllegalStateException("VLESS engine could not be started.")
    }
  }

  private fun startHealthChecks() {
    healthJob = scope.launch {
      var failures = 0
      while (isActive && enabled) {
        val lease = verification.lease()
        if (coreNetworkRevision != networkRevision) return@launch
        val started = System.nanoTime()
        val okay = runCatching {
          val running = invoke("getXrayState").optJSONObject("data")?.optBoolean("running") == true
          if (!running && verification.isCurrent(lease)) {
            verification.setCoreReady(false)
            verification.invalidate("data_plane_failed")
            scheduleRecovery(nextRecoveryDelay(), forceRestart = true)
            return@launch
          }
          running && VlessHttpsProbe.verify(socksPort, socksUser, socksPassword) { socket ->
            synchronized(proofSocketLock) {
              if (socket != null && verification.isCurrent(lease)) {
                proofSocket = socket
                proofOwner = lease
              } else if (socket == null && proofOwner == lease) {
                proofSocket = null
                proofOwner = null
              } else if (socket != null) socket.close()
            }
          }
        }.getOrDefault(false)
        if (okay && verification.confirm(lease, (System.nanoTime() - started) / 1_000_000)) {
          failures = 0
          recoveryFailures = 0
        } else if (verification.isCurrent(lease)) {
          verification.fail(lease)
          failures++
          if (failures >= 2) {
            scheduleRecovery(nextRecoveryDelay(), forceRestart = true)
            return@launch
          }
        }
        delay(if (okay) 10_000 else 2_000)
      }
    }
  }

  @Synchronized private fun refreshNetwork(schedule: Boolean = true) {
    if (destroyed) return
    val active = connectivity.activeNetwork
    val next = connectivity.allNetworks.mapNotNull { candidate ->
      val caps = connectivity.getNetworkCapabilities(candidate) ?: return@mapNotNull null
      if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) candidate to when {
        candidate == active -> 100
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 80
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 60
        else -> 40
      } else null
    }.maxByOrNull { it.second }?.first
    val dns = next?.let { dnsEndpoint(it) }.orEmpty()
    if (next == selectedNetwork && dns == selectedDns) return
    selectedNetwork = next
    selectedDns = dns
    networkRevision++
    // This executes immediately in the callback, before a status RPC can
    // observe proof earned on the old underlay. Native sockets are rebound
    // only through protected controllers when the core restarts below.
    verification.setCoreReady(false)
    verification.invalidate(if (next == null) "network_unavailable" else "probe_pending")
    synchronized(proofSocketLock) { runCatching { proofSocket?.close() }; proofSocket = null; proofOwner = null }
    if (schedule && enabled) scheduleRecovery(750)
  }

  private fun scheduleRecovery(waitMs: Long, forceRestart: Boolean = false) {
    recoveryJob?.cancel()
    val order = commandRevision.get()
    recoveryJob = scope.launch {
      delay(waitMs)
      operations.withLock {
        if (enabled && !destroyed && order == commandRevision.get()
          && (forceRestart || !coreRunning || coreNetworkRevision != networkRevision)) {
          try { restartCore(order) }
          catch (_: Throwable) {
            // Keep the original TUN while retrying a failed engine. Backoff
            // belongs to this native service, not to a Codex polling process.
            if (enabled && tunnel != null) scheduleRecovery(nextRecoveryDelay(), forceRestart = true)
          }
        }
      }
    }
  }

  private fun nextRecoveryDelay(): Long {
    recoveryFailures = (recoveryFailures + 1).coerceAtMost(5)
    return (3_000L shl recoveryFailures).coerceAtMost(60_000L)
  }

  private fun dnsEndpoint(network: Network): String {
    val server = connectivity.getLinkProperties(network)?.dnsServers?.firstOrNull {
      !it.isAnyLocalAddress && !it.isLoopbackAddress && !it.isLinkLocalAddress
    }?.hostAddress ?: "1.1.1.1"
    return if (':' in server) "[$server]:53" else "$server:53"
  }

  private fun invoke(method: String, config: String? = null): JSONObject {
    val request = JSONObject().put("apiVersion", 3).put("method", method)
    if (config != null) request.put("payload", JSONObject().put("xrayJson", config))
    val result = JSONObject(LibXray.invoke(request.toString()))
    if (!result.optBoolean("success")) throw IllegalStateException("VLESS core operation failed.")
    return result
  }

  private fun stopCore() {
    verification.setCoreReady(false)
    // A failed shutdown is not a successful release. The caller retains its
    // capture; an explicit release RPC failure lets the main-process watchdog
    // terminate this owned worker and close every duplicate FD.
    if (coreTouched) invoke("stopXray")
    coreRunning = false
    coreNetworkRevision = -1L
    if (coreTouched) runCatching { LibXray.resetDNS() }
  }

  private fun cancelProof() {
    healthJob?.cancel()
    healthJob = null
    synchronized(proofSocketLock) { runCatching { proofSocket?.close() }; proofSocket = null; proofOwner = null }
  }

  private fun closeTunnel() {
    runCatching { tunnel?.close() }
    tunnel = null
    verification.setCapture(false)
  }

  private fun disconnect(release: Boolean) {
    enabled = false
    recoveryJob?.cancel()
    recoveryJob = null
    verification.stop(retainCapture = !release)
    cancelProof()
    stopCore()
    outbound = null
    socksUser = ""
    socksPassword = ""
    if (release || tunnel == null) {
      closeTunnel()
      stopForeground(STOP_FOREGROUND_REMOVE)
      stopSelf()
    }
  }

  private fun status(): JSONObject {
    val current = verification.snapshot()
    return JSONObject().put("transport", "vless").put("state", current.state)
      .put("connectionId", current.connectionId).put("verified", current.verified)
      .put("connectionWanted", current.connectionWanted)
      .put("rxBytes", 0).put("txBytes", 0).put("leakProtection", current.leakProtection).apply {
        if (current.verificationEpochMillis > 0) put("verificationEpochMillis", current.verificationEpochMillis)
        current.verificationReason?.let { put("verificationReason", it) }
        current.latencyMs?.let { put("latencyMs", it) }
      }
  }

  private fun reply(request: Message, value: JSONObject?, error: String? = null) {
    runCatching {
      request.replyTo?.send(Message.obtain(null, request.what, request.arg1, 0).apply {
        data = Bundle().apply {
          if (value != null) putString(VlessVpnIpc.STATUS, value.toString())
          if (error != null) putString(VlessVpnIpc.ERROR, error)
        }
      })
    }
  }

  override fun onRevoke() {
    commandRevision.incrementAndGet()
    verification.invalidate("network_unavailable")
    enabled = false
    scope.launch { operations.withLock { disconnect(true) } }
    super.onRevoke()
  }

  override fun onDestroy() {
    commandRevision.incrementAndGet()
    destroyed = true
    enabled = false
    verification.stop(false)
    runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
    cancelProof()
    // Serialize against an already running JNI startup. Canceling its coroutine
    // does not cancel Go; cleanup must run after that operation releases the lock.
    scope.launch {
      operations.withLock {
        runCatching { stopCore() }
        closeTunnel()
        scope.cancel()
      }
    }
    super.onDestroy()
  }

  private fun notification(): Notification {
    val manager = getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL, "VEX VPN", NotificationManager.IMPORTANCE_LOW).apply {
      setSound(null, null); enableVibration(false); setShowBadge(false)
    })
    val launch = packageManager.getLaunchIntentForPackage(packageName)
    val pending = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
    val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    return builder.setContentTitle("VEX VPN").setContentText("Проверка и защита VPN-соединения")
      .setSmallIcon(android.R.drawable.stat_sys_warning).setOngoing(true).setOnlyAlertOnce(true)
      .setContentIntent(pending).setCategory(Notification.CATEGORY_SERVICE).build()
  }

  companion object {
    private const val CHANNEL = "vex_vless"
    private const val NOTIFICATION_ID = 9175
  }
}
