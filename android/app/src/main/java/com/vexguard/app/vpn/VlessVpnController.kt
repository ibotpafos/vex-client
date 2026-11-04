package com.vexguard.app.vpn

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.app.ActivityManager
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Binder-only main-process client. Never imports or initializes libXray. */
internal class VlessVpnController(context: Context) {
  private val app = context.applicationContext
  private val prefs = app.getSharedPreferences("vex_vpn_engine", Context.MODE_PRIVATE)
  private val intentJournal = VlessIntentJournal(app.filesDir)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val requests = ConcurrentHashMap<Int, CompletableDeferred<JSONObject>>()
  private val sequence = AtomicInteger()
  private var endpoint: Messenger? = null
  private var binding: CompletableDeferred<Messenger>? = null
  private var bound = false
  private var connection: ServiceConnection? = null
  private val callbackFence = VlessCallbackFence()
  @Volatile private var replacingWorker = false
  private val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
    if (message.sendingUid != android.os.Process.myUid()) return@Handler true
    val request = requests.remove(message.arg1) ?: return@Handler true
    val error = message.data.getString(VlessVpnIpc.ERROR)
    if (error != null) request.completeExceptionally(IllegalStateException("VLESS operation failed ($error)."))
    else runCatching { JSONObject(message.data.getString(VlessVpnIpc.STATUS) ?: "{}") }
      .onSuccess { request.complete(it) }.onFailure { request.completeExceptionally(IllegalStateException("VLESS status response is invalid.")) }
    true
  })

  fun isSelected() = prefs.getString("active_engine", "awg") == "vless"

  fun authorizeManualConnection() = intentJournal.authorizeManual()

  fun connectionAuthorization() = intentJournal.ticket()

  fun requiresPermissionRequest() = currentIntent().let { it.revoked || !(it.wanted || it.permit) }

  fun beginConnection(authorization: String, antiLeak: Boolean) = intentJournal.begin(authorization, antiLeak)

  fun selectAwg() {
    intentJournal.stop(false)
    prefs.edit().putString("active_engine", "awg").putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", false).commit()
  }

  fun cancelPendingConnection(releaseAntiLeak: Boolean) {
    intentJournal.stop(!releaseAntiLeak && prefs.getBoolean("vless_antileak", true))
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", !releaseAntiLeak && prefs.getBoolean("vless_antileak", true)).commit()
    runCatching {
      endpoint?.send(Message.obtain(null, VlessVpnIpc.DISCONNECT, 0, 0).apply {
        data = Bundle().apply { putBoolean(VlessVpnIpc.RELEASE, releaseAntiLeak) }
      })
    }
  }

  fun detach() {
    callbackFence.advance()
    val previous = connection
    if (bound && previous != null) runCatching { app.unbindService(previous) }
    connection = null
    bound = false
    endpoint = null
    binding?.completeExceptionally(IllegalStateException("VLESS worker binding was retired."))
    binding = null
    requests.values.forEach { it.completeExceptionally(IllegalStateException("VLESS worker binding was retired.")) }
    requests.clear()
  }

  /** Only the explicit release watchdog may terminate a stuck worker. */
  fun forceReleaseWorker() {
    intentJournal.stop(false)
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", false).commit()
    app.stopService(Intent().setComponent(ComponentName(app.packageName, VlessVpnIpc.SERVICE)))
    val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    manager.runningAppProcesses.orEmpty().filter {
      it.uid == android.os.Process.myUid() && it.processName == app.packageName + VlessVpnProcess.SUFFIX
    }.forEach { android.os.Process.killProcess(it.pid) }
  }

  suspend fun connect(config: String, antiLeak: Boolean, routing: String, packages: List<String>, selectedOnly: Boolean, attempt: String): JSONObject {
    // Reject unsupported policy/transport before either engine is mutated.
    VlessRuntimeConfig.admit(config, routing)
    check(intentJournal.isCurrent(attempt)) { "VLESS operation was superseded." }
    prefs.edit().putString("active_engine", "vless").putBoolean("vless_wanted", true)
      .putBoolean("vless_hold_capture", antiLeak)
      .putBoolean("vless_antileak", antiLeak).putStringSet("vless_packages", if (selectedOnly) packages.toSet() else emptySet()).commit()
    replacingWorker = true
    val response = try {
      retireWorker(attempt, antiLeak, packages)
      request(VlessVpnIpc.CONNECT, Bundle().apply {
        putString(VlessVpnIpc.CONFIG, config)
        putString(VlessVpnIpc.INTENT, attempt)
        putString(VlessVpnIpc.ROUTING, routing)
        putBoolean(VlessVpnIpc.ANTILEAK, antiLeak)
        putBoolean(VlessVpnIpc.SELECTED_ONLY, selectedOnly)
        putStringArrayList(VlessVpnIpc.PACKAGES, ArrayList(packages))
      }, start = true)
    } finally { replacingWorker = false }
    prefs.edit().putString("vless_connection", response.optString("connectionId")).commit()
    return authoritativeStatus(response)
  }

  suspend fun disconnect(releaseAntiLeak: Boolean): JSONObject {
    intentJournal.stop(!releaseAntiLeak && prefs.getBoolean("vless_antileak", true))
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", !releaseAntiLeak && prefs.getBoolean("vless_antileak", true)).commit()
    val response = runCatching { request(VlessVpnIpc.DISCONNECT, Bundle().apply {
      putBoolean(VlessVpnIpc.RELEASE, releaseAntiLeak)
    }) }.getOrElse {
      // A dead worker cannot retain its TUN. Preserve an explicitly requested
      // block in the independent, existing main-process blocker instead.
      if (!releaseAntiLeak && captureWanted() && prefs.getBoolean("vless_antileak", true)) protectAfterWorkerLoss()
      if (releaseAntiLeak) forceReleaseWorker()
      disconnectedSnapshot()
    }
    if (releaseAntiLeak) {
      require(VexLeakBlockerService.stopAndAwait(app)) { "VPN leak protection did not release." }
    }
    return authoritativeStatus(response)
  }

  suspend fun status(): JSONObject {
    if (replacingWorker) return replacementSnapshot()
    if (!captureWanted() && endpoint == null) return disconnectedSnapshot()
    return runCatching { request(VlessVpnIpc.READ_STATUS) }.getOrElse {
      if (replacingWorker) return@getOrElse replacementSnapshot()
      if (captureWanted() && prefs.getBoolean("vless_antileak", true)) protectAfterWorkerLoss()
      disconnectedSnapshot().put("state", "error").put("verificationReason", "network_unavailable")
    }.let(::authoritativeStatus)
  }

  private fun replacementSnapshot() = disconnectedSnapshot().put("state", "verifying")
    .put("verificationReason", "probe_pending")

  private suspend fun retireWorker(attempt: String, antiLeak: Boolean, packages: List<String>) {
    check(intentJournal.isCurrent(attempt)) { "VLESS operation was superseded." }
    // The new journal attempt has already retired the old worker's authority.
    // An owned blocker carries capture across process retirement; establish()
    // cannot reclaim another app's VPN and no prepare() call occurs here.
    if (antiLeak && !VexLeakBlockerService.startAndAwait(app, packages)) {
      intentJournal.revoke(attempt)
      throw IllegalStateException("VLESS handover protection is unavailable.")
    }
    check(intentJournal.isCurrent(attempt)) { "VLESS operation was superseded." }
    val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    fun workers() = manager.runningAppProcesses.orEmpty().filter {
      it.uid == android.os.Process.myUid() && it.processName == app.packageName + VlessVpnProcess.SUFFIX
    }
    withContext(Dispatchers.Main.immediate) {
      detach()
      app.stopService(Intent().setComponent(ComponentName(app.packageName, VlessVpnIpc.SERVICE)))
      workers().forEach { android.os.Process.killProcess(it.pid) }
    }
    // Never bind a successor until every old system callback recipient is dead.
    withTimeout(5_000L) { while (workers().isNotEmpty()) delay(50) }
    check(intentJournal.isCurrent(attempt)) { "VLESS operation was superseded." }
  }

  // Retained capture protects traffic after an explicit disconnect but is
  // never authority to reconnect. Only the persisted active connection intent is.
  private fun currentIntent(): VlessIntentJournal.State = intentJournal.snapshot().also {
    if (it.revoked) prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", false).commit()
  }

  private fun connectionWanted() = isSelected() && currentIntent().let { it.wanted && !it.revoked }

  private fun captureWanted() = currentIntent().let { !it.revoked && (it.wanted || it.hold) }

  private fun authoritativeStatus(value: JSONObject): JSONObject {
    val intent = currentIntent()
    val wanted = isSelected() && intent.wanted && !intent.revoked
    value.put("connectionWanted", wanted)
    if (!wanted || value.optString(VlessVpnIpc.INTENT) != intent.attemptId) {
      value.put("verified", false).remove("verificationEpochMillis")
      value.remove("latencyMs")
    }
    if (wanted && value.has(VlessVpnIpc.INTENT) && value.optString(VlessVpnIpc.INTENT) != intent.attemptId) {
      value.put("state", "verifying").put("verificationReason", "probe_pending").put("leakProtection", "off")
    }
    if (!wanted) VlessStatusAuthority.withdrawn(value, intent.hold && !intent.revoked)
    if (intent.revoked) value.put("state", "disconnected").put("leakProtection", "off")
    value.remove(VlessVpnIpc.INTENT)
    return value
  }

  private fun disconnectedSnapshot() = JSONObject().put("transport", "vless")
    .put("state", if (VexLeakBlockerService.isActive()) "error" else "disconnected")
    .put("connectionId", prefs.getString("vless_connection", ""))
    .put("connectionWanted", connectionWanted())
    .put("verified", false).put("rxBytes", 0).put("txBytes", 0)
    .put("leakProtection", if (VexLeakBlockerService.isActive()) "blocking" else "off")

  private suspend fun protectAfterWorkerLoss() {
    if (!VexLeakBlockerService.isActive() && intentJournal.prepareRecoveryCapture()) {
      VexLeakBlockerService.startAndAwait(app, prefs.getStringSet("vless_packages", emptySet()).orEmpty().toList())
    }
  }

  private fun lostService() {
    endpoint = null
    binding?.completeExceptionally(IllegalStateException("VLESS worker is unavailable."))
    binding = null
    requests.values.forEach { it.completeExceptionally(IllegalStateException("VLESS worker stopped.")) }
    requests.clear()
    if (isSelected() && captureWanted() && prefs.getBoolean("vless_antileak", true)) {
      scope.launch { runCatching { protectAfterWorkerLoss() } }
    }
  }

  private suspend fun ensureEndpoint(start: Boolean): Messenger = withContext(Dispatchers.Main.immediate) {
    endpoint?.let { return@withContext it }
    binding?.let { return@withContext withTimeout(5_000L) { it.await() } }
    val intent = Intent(VlessVpnIpc.ACTION).setComponent(ComponentName(app.packageName, VlessVpnIpc.SERVICE))
    if (bound) {
      val previous = connection
      if (previous != null) runCatching { app.unbindService(previous) }
      bound = false
    }
    if (start) ContextCompat.startForegroundService(app, intent)
    val pending = CompletableDeferred<Messenger>()
    binding = pending
    val generation = callbackFence.advance()
    val current = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, service: IBinder) {
        if (!callbackFence.isCurrent(generation)) return
        endpoint = Messenger(service)
        binding?.complete(endpoint!!)
        binding = null
      }
      override fun onServiceDisconnected(name: ComponentName) { if (callbackFence.isCurrent(generation)) lostService() }
      override fun onBindingDied(name: ComponentName) { if (callbackFence.isCurrent(generation)) lostService() }
      override fun onNullBinding(name: ComponentName) { if (callbackFence.isCurrent(generation)) lostService() }
    }
    connection = current
    bound = app.bindService(intent, current, if (start) Context.BIND_AUTO_CREATE else 0)
    if (!bound) {
      binding = null
      throw IllegalStateException("VLESS worker is unavailable.")
    }
    try { withTimeout(5_000L) { pending.await() } }
    finally { if (binding === pending) binding = null }
  }

  private suspend fun request(command: Int, data: Bundle = Bundle(), start: Boolean = false): JSONObject {
    val messenger = ensureEndpoint(start)
    val id = sequence.incrementAndGet()
    val pending = CompletableDeferred<JSONObject>()
    requests[id] = pending
    try {
      if (command == VlessVpnIpc.CONNECT && !intentJournal.isCurrent(data.getString(VlessVpnIpc.INTENT).orEmpty())) {
        throw IllegalStateException("VLESS operation was superseded.")
      }
      messenger.send(Message.obtain(null, command, id, 0).apply { this.data = data; replyTo = reply })
      return withTimeout(if (command == VlessVpnIpc.CONNECT) 20_000L else 5_000L) { pending.await() }
    } finally { requests.remove(id) }
  }
}

internal object VlessVpnIpc {
  const val SERVICE = "com.vexguard.app.vpn.VlessVpnService"
  const val ACTION = "com.vexguard.app.vpn.VLESS_CONTROL"
  const val CONNECT = 1
  const val DISCONNECT = 2
  const val READ_STATUS = 3
  const val CONFIG = "config"
  const val INTENT = "connection_intent"
  const val ROUTING = "routing"
  const val ANTILEAK = "antileak"
  const val SELECTED_ONLY = "selected_only"
  const val PACKAGES = "packages"
  const val RELEASE = "release"
  const val STATUS = "status"
  const val ERROR = "error"
}
