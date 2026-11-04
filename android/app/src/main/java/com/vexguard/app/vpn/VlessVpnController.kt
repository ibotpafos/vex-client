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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Binder-only main-process client. Never imports or initializes libXray. */
internal class VlessVpnController(context: Context) {
  private val app = context.applicationContext
  private val prefs = app.getSharedPreferences("vex_vpn_engine", Context.MODE_PRIVATE)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val requests = ConcurrentHashMap<Int, CompletableDeferred<JSONObject>>()
  private val sequence = AtomicInteger()
  private var endpoint: Messenger? = null
  private var binding: CompletableDeferred<Messenger>? = null
  private var bound = false
  private val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
    if (message.sendingUid != android.os.Process.myUid()) return@Handler true
    val request = requests.remove(message.arg1) ?: return@Handler true
    val error = message.data.getString(VlessVpnIpc.ERROR)
    if (error != null) request.completeExceptionally(IllegalStateException("VLESS operation failed ($error)."))
    else runCatching { JSONObject(message.data.getString(VlessVpnIpc.STATUS) ?: "{}") }
      .onSuccess { request.complete(it) }.onFailure { request.completeExceptionally(IllegalStateException("VLESS status response is invalid.")) }
    true
  })
  private val connection = object : ServiceConnection {
    override fun onServiceConnected(name: ComponentName, service: IBinder) {
      endpoint = Messenger(service)
      binding?.complete(endpoint!!)
      binding = null
    }
    override fun onServiceDisconnected(name: ComponentName) = lostService()
    override fun onBindingDied(name: ComponentName) = lostService()
    override fun onNullBinding(name: ComponentName) = lostService()
  }

  fun isSelected() = prefs.getString("active_engine", "awg") == "vless"

  fun selectAwg() { prefs.edit().putString("active_engine", "awg").putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", false).commit() }

  fun cancelPendingConnection(releaseAntiLeak: Boolean) {
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", !releaseAntiLeak && prefs.getBoolean("vless_antileak", true)).commit()
    runCatching {
      endpoint?.send(Message.obtain(null, VlessVpnIpc.DISCONNECT, 0, 0).apply {
        data = Bundle().apply { putBoolean(VlessVpnIpc.RELEASE, releaseAntiLeak) }
      })
    }
  }

  fun detach() {
    if (bound) runCatching { app.unbindService(connection) }
    bound = false
    endpoint = null
  }

  /** Only the explicit release watchdog may terminate a stuck worker. */
  fun forceReleaseWorker() {
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", false).commit()
    app.stopService(Intent().setComponent(ComponentName(app.packageName, VlessVpnIpc.SERVICE)))
    val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    manager.runningAppProcesses.orEmpty().filter {
      it.uid == android.os.Process.myUid() && it.processName == app.packageName + VlessVpnProcess.SUFFIX
    }.forEach { android.os.Process.killProcess(it.pid) }
  }

  suspend fun connect(config: String, antiLeak: Boolean, routing: String, packages: List<String>, selectedOnly: Boolean): JSONObject {
    // Reject unsupported policy/transport before either engine is mutated.
    VlessRuntimeConfig.admit(config, routing)
    prefs.edit().putString("active_engine", "vless").putBoolean("vless_wanted", true)
      .putBoolean("vless_hold_capture", antiLeak)
      .putBoolean("vless_antileak", antiLeak).putStringSet("vless_packages", if (selectedOnly) packages.toSet() else emptySet()).commit()
    val response = request(VlessVpnIpc.CONNECT, Bundle().apply {
      putString(VlessVpnIpc.CONFIG, config)
      putString(VlessVpnIpc.ROUTING, routing)
      putBoolean(VlessVpnIpc.ANTILEAK, antiLeak)
      putBoolean(VlessVpnIpc.SELECTED_ONLY, selectedOnly)
      putStringArrayList(VlessVpnIpc.PACKAGES, ArrayList(packages))
    }, start = true)
    prefs.edit().putString("vless_connection", response.optString("connectionId")).commit()
    return response.put("connectionWanted", connectionWanted())
  }

  suspend fun disconnect(releaseAntiLeak: Boolean): JSONObject {
    prefs.edit().putBoolean("vless_wanted", false).putBoolean("vless_hold_capture", !releaseAntiLeak && prefs.getBoolean("vless_antileak", true)).commit()
    val response = runCatching { request(VlessVpnIpc.DISCONNECT, Bundle().apply {
      putBoolean(VlessVpnIpc.RELEASE, releaseAntiLeak)
    }) }.getOrElse {
      // A dead worker cannot retain its TUN. Preserve an explicitly requested
      // block in the independent, existing main-process blocker instead.
      if (!releaseAntiLeak && prefs.getBoolean("vless_antileak", true)) protectAfterWorkerLoss()
      if (releaseAntiLeak) forceReleaseWorker()
      disconnectedSnapshot()
    }
    if (releaseAntiLeak) {
      require(VexLeakBlockerService.stopAndAwait(app)) { "VPN leak protection did not release." }
    }
    return response.put("connectionWanted", connectionWanted())
  }

  suspend fun status(): JSONObject {
    if (!captureWanted() && endpoint == null) return disconnectedSnapshot()
    return runCatching { request(VlessVpnIpc.READ_STATUS) }.getOrElse {
      if (captureWanted() && prefs.getBoolean("vless_antileak", true)) protectAfterWorkerLoss()
      disconnectedSnapshot().put("state", "error").put("verificationReason", "network_unavailable")
    }.put("connectionWanted", connectionWanted())
  }

  // Retained capture protects traffic after an explicit disconnect but is
  // never authority to reconnect. Only the persisted active connection intent is.
  private fun connectionWanted() = isSelected() && prefs.getBoolean("vless_wanted", false)

  private fun captureWanted() = prefs.getBoolean("vless_wanted", false) || prefs.getBoolean("vless_hold_capture", false)

  private fun disconnectedSnapshot() = JSONObject().put("transport", "vless")
    .put("state", if (VexLeakBlockerService.isActive()) "error" else "disconnected")
    .put("connectionId", prefs.getString("vless_connection", ""))
    .put("connectionWanted", connectionWanted())
    .put("verified", false).put("rxBytes", 0).put("txBytes", 0)
    .put("leakProtection", if (VexLeakBlockerService.isActive()) "blocking" else "off")

  private suspend fun protectAfterWorkerLoss() {
    if (!VexLeakBlockerService.isActive()) {
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
      runCatching { app.unbindService(connection) }
      bound = false
    }
    if (start) ContextCompat.startForegroundService(app, intent)
    val pending = CompletableDeferred<Messenger>()
    binding = pending
    bound = app.bindService(intent, connection, if (start) Context.BIND_AUTO_CREATE else 0)
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
      if (command == VlessVpnIpc.CONNECT && !prefs.getBoolean("vless_wanted", false)) {
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
  const val ROUTING = "routing"
  const val ANTILEAK = "antileak"
  const val SELECTED_ONLY = "selected_only"
  const val PACKAGES = "packages"
  const val RELEASE = "release"
  const val STATUS = "status"
  const val ERROR = "error"
}
