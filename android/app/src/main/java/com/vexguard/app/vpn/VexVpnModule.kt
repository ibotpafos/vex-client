package com.vexguard.app.vpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.util.Base64
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.BaseActivityEventListener
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.google.firebase.messaging.FirebaseMessaging
import io.sentry.Sentry
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.URL
import java.security.MessageDigest

class VexVpnModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), LifecycleEventListener {
  private val controller = WireGuardController(reactContext)
  private val apiRecoveryTransport = ApiRecoveryTransport { controller.apiRecoveryNetwork() }
  private val vlessController = VlessVpnController(reactContext)
  private val engineOperations = Mutex()
  private val awgIntentPrefs = reactContext.getSharedPreferences("vex_awg_intent", android.content.Context.MODE_PRIVATE)
  private val engineRevision = VpnEngineRevision(
    if (awgIntentPrefs.contains("wanted")) awgIntentPrefs.getBoolean("wanted", false) else null,
    { wanted -> check(awgIntentPrefs.edit().putBoolean("wanted", wanted).commit()) { "VPN intent storage failed." } },
  )
  private val wireGuardKeyStore = WireGuardKeyStore(reactContext)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val verificationHandler = Handler(Looper.getMainLooper())
  private val verificationTimers = VpnVerificationTimers(
    { task, delayMs -> verificationHandler.postDelayed(task, delayMs) },
    { task -> verificationHandler.removeCallbacks(task) },
  )
  private var pendingPermissionPromise: Promise? = null
  private var listenerCount = 0
  private var statusEmitterJob: Job? = null
  private var lastEmittedVpnStatus: WritableMap? = null

  private val activityEventListener = object : BaseActivityEventListener() {
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
      if (requestCode != REQUEST_VPN_PERMISSION) {
        return
      }

      val promise = pendingPermissionPromise ?: return
      pendingPermissionPromise = null

      if (resultCode == Activity.RESULT_OK) {
        try {
          vlessController.authorizeManualConnection()
          promise.resolve(true)
        } catch (_: Throwable) {
          promise.reject("VPN_PERMISSION_STATE_FAILED", "VPN permission state could not be recorded.")
        }
      } else {
        promise.reject("VPN_PERMISSION_DENIED", "Android VPN permission was denied.")
      }
    }
  }

  init {
    reactContext.addActivityEventListener(activityEventListener)
    reactContext.addLifecycleEventListener(this)
  }

  override fun getName(): String = "VexVpn"

  @ReactMethod
  fun requestApiRecovery(id: String, url: String, method: String, headers: ReadableMap,
                         body: String?, deadlineEpochMillis: Double, promise: Promise) {
    apiRecoveryTransport.request(id, url, method, headers, body, deadlineEpochMillis, promise)
  }

  @ReactMethod
  fun cancelApiRecovery(id: String) { apiRecoveryTransport.cancel(id) }

  @ReactMethod
  fun networkObservation(promise: Promise) {
    val result = Arguments.createMap()
    controller.networkObservation().forEach { (key, value) -> result.putString(key, value) }
    promise.resolve(result)
  }

  @ReactMethod
  fun needsPermission(promise: Promise) {
    // prepare() can change ownership on Android 9. VLESS permission hints and
    // every automatic status/recovery path use the durable intent instead.
    promise.resolve(if (vlessController.isSelected()) vlessController.requiresPermissionRequest() else controller.needsPermission())
  }

  @ReactMethod
  fun requestPermission(promise: Promise) {
    val intent = VpnService.prepare(reactContext)
    if (intent == null) {
      try {
        vlessController.authorizeManualConnection()
        promise.resolve(true)
      } catch (_: Throwable) {
        promise.reject("VPN_PERMISSION_STATE_FAILED", "VPN permission state could not be recorded.")
      }
      return
    }

    val activity = reactApplicationContext.currentActivity
    if (activity == null) {
      promise.reject("NO_ACTIVITY", "Cannot request VPN permission without an active Activity.")
      return
    }

    if (pendingPermissionPromise != null) {
      promise.reject("VPN_PERMISSION_IN_PROGRESS", "A VPN permission request is already in progress.")
      return
    }

    pendingPermissionPromise = promise
    activity.startActivityForResult(intent, REQUEST_VPN_PERMISSION)
  }

  @ReactMethod
  fun connect(wgQuickConfig: String, antiLeakEnabled: Boolean, promise: Promise) {
    startConnection(
      wgQuickConfig = wgQuickConfig,
      antiLeakEnabled = antiLeakEnabled,
      selectedApplications = emptyList(),
      routeOnlySelectedApplications = false,
      promise = promise,
    )
  }

  @ReactMethod
  fun connectWithApplications(
    wgQuickConfig: String,
    antiLeakEnabled: Boolean,
    selectedApplications: ReadableArray,
    routeOnlySelectedApplications: Boolean,
    promise: Promise,
  ) {
    val packages = (0 until selectedApplications.size())
      .mapNotNull { selectedApplications.getString(it)?.trim() }
      .filter { it.isNotEmpty() }
      .distinct()
    startConnection(
      wgQuickConfig = wgQuickConfig,
      antiLeakEnabled = antiLeakEnabled,
      selectedApplications = packages,
      routeOnlySelectedApplications = routeOnlySelectedApplications,
      promise = promise,
    )
  }

  private fun startConnection(
    wgQuickConfig: String,
    antiLeakEnabled: Boolean,
    selectedApplications: List<String>,
    routeOnlySelectedApplications: Boolean,
    promise: Promise,
    routingParameters: String? = null,
  ) {
    val operation = nextEngineRevision(true, promise) ?: return
    val recoveryHandler = Handler(Looper.getMainLooper())
    val settled = java.util.concurrent.atomic.AtomicBoolean(false)
    val hardRecovery = object : Runnable {
      override fun run() {
        if (operation != engineRevision.get()) return
        if (controller.isNetworkRecoveryPending()) {
          Log.w(TAG, "Delaying VPN connect hard recovery while network recovery is active.")
          recoveryHandler.postDelayed(this, NETWORK_RECOVERY_HARD_TIMEOUT_RETRY_MS)
          return
        }
        if (antiLeakEnabled && controller.hasProtectedRoutingCapture()) {
          Log.e(TAG, "VPN connect timed out; keeping the protected capture installed.")
          if (settled.compareAndSet(false, true)) promise.reject("VPN_CONNECT_TIMEOUT", "VPN connection timed out; leak protection remains active.")
          return
        }
        Log.e(TAG, "VPN connect exceeded ${CONNECT_HARD_RECOVERY_MS}ms; terminating the app process to release Android VPN descriptors.")
        VexLeakBlockerService.stop(reactContext)
        android.os.Process.killProcess(android.os.Process.myPid())
      }
    }
    recoveryHandler.postDelayed(hardRecovery, CONNECT_HARD_RECOVERY_MS)
    scope.launchVpnControlOperation(
      onCompletion = { recoveryHandler.removeCallbacks(hardRecovery) },
    ) {
      try {
        val status = engineOperations.withLock {
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          if (vlessController.isSelected()) {
            AwgConfigSafety.parseForActivation(wgQuickConfig)
            vlessController.disconnect(releaseAntiLeak = !antiLeakEnabled)
            if (antiLeakEnabled && !VexLeakBlockerService.startAndAwait(
                reactContext, if (routeOnlySelectedApplications) selectedApplications else emptyList())) {
              throw IllegalStateException("VPN protection could not be retained during engine handover.")
            }
          }
          // Also retire a VLESS attempt queued before its active-engine flag
          // reached preferences; the operation revision has already replaced it.
          vlessController.selectAwg()
          val connected = controller.connect(
            wgQuickConfig,
            antiLeakEnabled,
            routeOnlySelectedApplications,
            selectedApplications,
            routingParameters,
          ).toWritableMap()
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          connected
        }
        emitVpnStatusChanged(status, force = true)
        if (settled.compareAndSet(false, true)) promise.resolve(status)
      } catch (error: VpnPermissionRequiredException) {
        if (settled.compareAndSet(false, true)) rejectVpnError(promise, "VPN_PERMISSION_REQUIRED", "Android VPN permission is required.", error)
      } catch (error: Throwable) {
        if (settled.compareAndSet(false, true)) rejectVpnError(promise, "VPN_CONNECT_FAILED", "VPN connection failed.", error)
      }
    }
  }

  @ReactMethod
  fun connectWithRoutingPolicy(
    config: String, antiLeakEnabled: Boolean, routingParameters: String,
    applications: ReadableArray, selectedOnly: Boolean, promise: Promise,
  ) {
    val packages = (0 until applications.size()).mapNotNull { applications.getString(it)?.trim() }.filter { it.isNotEmpty() }.distinct()
    startConnection(config, antiLeakEnabled, packages, selectedOnly, promise, routingParameters)
  }

  @ReactMethod
  fun connectVless(
    xrayConfig: String, antiLeakEnabled: Boolean, routingParameters: String,
    applications: ReadableArray, selectedOnly: Boolean, promise: Promise,
  ) {
    val operation = nextEngineRevision(null, promise) ?: return
    // Capture before asynchronous work. Revocation/manual reauthorization
    // rotates this fence, so an already queued recovery cannot adopt it.
    val authorization = runCatching { vlessController.connectionAuthorization() }.getOrNull()
    val packages = (0 until applications.size()).mapNotNull { applications.getString(it)?.trim() }
      .filter { it.isNotEmpty() }.distinct()
    scope.launch {
      try {
        // Validate before stopping AWG or replacing a working VPN capture.
        VlessRuntimeConfig.admit(xrayConfig, routingParameters)
        val admitted = VlessApplicationSelection.admit(reactContext, packages, selectedOnly)
        val status = engineOperations.withLock {
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          val attempt = vlessController.beginConnection(checkNotNull(authorization), antiLeakEnabled)
          if (!vlessController.isSelected()) controller.disconnect(releaseAntiLeak = !antiLeakEnabled)
          // A failed retirement may leave AWG active and still needing recovery.
          check(engineRevision.setAwgWanted(operation, false)) { "VPN operation was superseded." }
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          val connected = vlessController.connect(xrayConfig, antiLeakEnabled, routingParameters, admitted.allowed, selectedOnly, attempt).toVlessWritableMap()
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          connected
        }
        emitVpnStatusChanged(status, force = true)
        promise.resolve(status)
      } catch (_: Throwable) {
        // A parser/core exception can quote a credential-bearing config. Keep
        // this public bridge failure fixed and free of the original exception.
        rejectVpnError(promise, "VPN_VLESS_CONNECT_FAILED", "VLESS connection failed.", IllegalStateException("VLESS connection failed."))
      }
    }
  }

  @ReactMethod
  fun getInstalledApplications(promise: Promise) {
    scope.launch {
      try {
        val applications = withContext(Dispatchers.IO) { installedApplications() }
        promise.resolve(applications)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_APPLICATIONS_FAILED", "Installed applications are unavailable.", error)
      }
    }
  }

  @ReactMethod
  fun disconnect(releaseAntiLeak: Boolean, promise: Promise) {
    // A user stop withdraws recovery intent before waiting for an older command.
    val operation = nextEngineRevision(if (releaseAntiLeak) false else null, promise) ?: return
    // Pending VLESS startup may not have changed active_engine yet.
    vlessController.cancelPendingConnection(releaseAntiLeak)
    val recoveryHandler = Handler(Looper.getMainLooper())
    val hardRecovery = object : Runnable {
      override fun run() {
        if (operation != engineRevision.get()) return
        if (vlessController.isSelected()) {
          // Explicit user release must also release a stuck remote Go core;
          // killing the React Native process would leave its separate TUN alive.
          vlessController.forceReleaseWorker()
          VexLeakBlockerService.stop(reactContext)
          return
        }
        if (controller.isNetworkRecoveryPending()) {
          Log.w(TAG, "Delaying VPN disconnect hard recovery while network recovery is active.")
          recoveryHandler.postDelayed(this, NETWORK_RECOVERY_HARD_TIMEOUT_RETRY_MS)
          return
        }
        Log.e(TAG, "VPN disconnect exceeded ${DISCONNECT_HARD_RECOVERY_MS}ms; terminating the app process to release Android VPN descriptors.")
        VexLeakBlockerService.stop(reactContext)
        android.os.Process.killProcess(android.os.Process.myPid())
      }
    }
    if (releaseAntiLeak) {
      recoveryHandler.postDelayed(hardRecovery, DISCONNECT_HARD_RECOVERY_MS)
    }
    scope.launchVpnControlOperation(
      onCompletion = { recoveryHandler.removeCallbacks(hardRecovery) },
    ) {
      try {
        val status = engineOperations.withLock {
          check(operation == engineRevision.get()) { "VPN operation was superseded." }
          if (vlessController.isSelected()) vlessController.disconnect(releaseAntiLeak).toVlessWritableMap()
          else controller.disconnect(releaseAntiLeak).toWritableMap()
        }
        emitVpnStatusChanged(status, force = true)
        promise.resolve(status)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_DISCONNECT_FAILED", "VPN disconnect failed.", error)
      }
    }
  }

  @ReactMethod
  fun openVpnSettings(promise: Promise) {
    try {
      val intent = Intent(Settings.ACTION_VPN_SETTINGS).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      reactContext.startActivity(intent)
      promise.resolve(true)
    } catch (error: Throwable) {
      rejectVpnError(promise, "VPN_SETTINGS_FAILED", "VPN settings could not be opened.", error)
    }
  }

  @ReactMethod
  /** Resolve from a Handler even while React Native UI-frame timers are paused. */
  fun scheduleVerificationTimer(id: String, delayMs: Double, promise: Promise) {
    if (!verificationTimers.schedule(id, delayMs) { expired -> promise.resolve(expired) }) {
      promise.reject("VPN_VERIFICATION_TIMER_FAILED", "VPN verification timer is unavailable.")
    }
  }

  @ReactMethod
  /** Cancel only the explicitly owned verification timer. */
  fun cancelVerificationTimer(id: String) {
    verificationTimers.cancel(id)
  }

  @ReactMethod
  fun status(promise: Promise) {
    scope.launch {
      try {
        val status = currentVpnStatus()
        emitVpnStatusChanged(status)
        promise.resolve(status)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_STATUS_FAILED", "VPN status check failed.", error)
      }
    }
  }

  @ReactMethod
  fun addListener(eventName: String) {
    if (eventName != VPN_STATUS_CHANGED_EVENT) {
      return
    }
    listenerCount += 1
    ensureStatusEmitterRunning()
  }

  @ReactMethod
  fun removeListeners(count: Double) {
    listenerCount = (listenerCount - count.toInt()).coerceAtLeast(0)
    if (listenerCount == 0) {
      stopStatusEmitter()
    }
  }

  @ReactMethod
  fun getOrCreateWireGuardKeyPair(promise: Promise) {
    scope.launch {
      try {
        promise.resolve(wireGuardKeyStore.getOrCreateKeyPair().toWritableMap())
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_KEYPAIR_FAILED", "WireGuard keypair is unavailable.", error)
      }
    }
  }

  @ReactMethod
  fun generateWireGuardKeyPair(promise: Promise) {
    scope.launch {
      try {
        promise.resolve(wireGuardKeyStore.generateNextKeyPair().toWritableMap())
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_KEYPAIR_GENERATE_FAILED", "WireGuard keypair generation failed.", error)
      }
    }
  }

  @ReactMethod
  fun replaceWireGuardKeyPair(privateKey: String, publicKey: String, keyEpoch: Double, promise: Promise) {
    try {
      wireGuardKeyStore.replaceKeyPair(
        StoredWireGuardKeyPair(
          privateKey = privateKey.trim(),
          publicKey = publicKey.trim(),
          keyEpoch = keyEpoch.toInt(),
        ),
      )
      promise.resolve(true)
    } catch (error: Throwable) {
      rejectVpnError(promise, "VPN_KEYPAIR_REPLACE_FAILED", "WireGuard keypair replacement failed.", error)
    }
  }

  @ReactMethod
  fun resetWireGuardKeyPair(promise: Promise) {
    try {
      wireGuardKeyStore.resetKeyPair()
      promise.resolve(true)
    } catch (error: Throwable) {
      rejectVpnError(promise, "VPN_KEYPAIR_RESET_FAILED", "WireGuard keypair reset failed.", error)
    }
  }

  @ReactMethod
  fun measureEndpointLatency(endpoint: String, promise: Promise) {
    scope.launch {
      try {
        if (vlessController.isSelected()) {
          val current = vlessController.status()
          promise.resolve(if (current.optBoolean("verified") && current.has("latencyMs")) current.optDouble("latencyMs") else null)
        } else promise.resolve(controller.measureEndpointLatency(endpoint))
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_LATENCY_FAILED", "VPN latency check failed.", error)
      }
    }
  }

  @ReactMethod
  fun readDiagnostics(promise: Promise) {
    scope.launch {
      try {
        val event = Arguments.createMap()
        event.putString("source", "android-native")
        event.putString("event", "vpn_status_snapshot")
        event.putMap("status", currentVpnStatus())
        val events = Arguments.createArray()
        events.pushMap(event)
        promise.resolve(events)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_DIAGNOSTICS_FAILED", "VPN diagnostics read failed.", error)
      }
    }
  }

  @ReactMethod
  fun requestNotificationPermission(promise: Promise) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      promise.resolve(true)
      return
    }
    if (ContextCompat.checkSelfPermission(reactContext, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
      promise.resolve(true)
      return
    }
    val activity = reactApplicationContext.currentActivity
    if (activity == null) {
      promise.resolve(false)
      return
    }
    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATION_PERMISSION)
    promise.resolve(false)
  }

  @ReactMethod
  fun getFirebaseMessagingToken(promise: Promise) {
    try {
      FirebaseMessaging.getInstance().token
        .addOnSuccessListener { token ->
          promise.resolve(token.orEmpty())
        }
        .addOnFailureListener { error ->
          Log.w(TAG, "FCM token is unavailable: ${error.message}")
          promise.resolve("")
        }
        .addOnCanceledListener {
          promise.resolve("")
        }
    } catch (error: Throwable) {
      Log.w(TAG, "FCM is not initialized: ${error.message}")
      promise.resolve("")
    }
  }

  @ReactMethod
  fun pendingDevicePushEvents(promise: Promise) {
    val events = Arguments.createArray()
    DevicePushEventQueue.pending(reactContext).forEach { item ->
      val value = Arguments.createMap()
      item.forEach { (key, field) -> value.putString(key, field) }
      events.pushMap(value)
    }
    promise.resolve(events)
  }

  @ReactMethod
  fun acknowledgeDevicePushEvent(eventID: String, promise: Promise) {
    DevicePushEventQueue.acknowledge(reactContext, eventID)
    promise.resolve(true)
  }

  @ReactMethod
  fun downloadUpdateApk(downloadUrl: String, checksumSha256: String?, promise: Promise) {
    scope.launch {
      try {
        Log.i(TAG, "Starting Android APK update download.")
        val result = withContext(Dispatchers.IO) {
          downloadAndVerifyApk(downloadUrl, checksumSha256)
        }
        Log.i(TAG, "Android APK update downloaded: ${result.sizeBytes} bytes.")
        val map = Arguments.createMap()
        map.putString("filePath", result.file.absolutePath)
        map.putDouble("sizeBytes", result.sizeBytes.toDouble())
        map.putString("checksumSha256", result.checksumSha256)
        promise.resolve(map)
      } catch (error: Throwable) {
        Log.e(TAG, "Android APK update download failed: ${error.message}", error)
        promise.reject("UPDATE_DOWNLOAD_FAILED", error.message, error)
      }
    }
  }

  @ReactMethod
  fun installUpdateApk(filePath: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists() || file.length() <= 0L) {
        promise.reject("UPDATE_APK_NOT_FOUND", "Downloaded APK was not found.")
        return
      }

      verifyDownloadedApkIdentity(file, checksumVerified = hasVerifiedChecksumSidecar(file))
      if (!canRequestPackageInstalls()) {
        rememberPendingUpdateApk(file)
        openUnknownSourcesSettings()
        promise.resolve(updateInstallResult("install_permission_required"))
        return
      }

      openPackageInstaller(file)
      clearPendingUpdateApk()
      promise.resolve(updateInstallResult("installer_started"))
    } catch (error: Throwable) {
      promise.reject("UPDATE_INSTALL_FAILED", error.message ?: "Не удалось открыть установщик APK.", error)
    }
  }

  override fun invalidate() {
    apiRecoveryTransport.close()
    verificationTimers.clear()
    pendingPermissionPromise?.reject("MODULE_INVALIDATED", "VexVpn module was invalidated.")
    pendingPermissionPromise = null
    stopStatusEmitter()
    vlessController.detach()
    reactContext.removeActivityEventListener(activityEventListener)
    reactContext.removeLifecycleEventListener(this)
    scope.cancel()
    super.invalidate()
  }

  override fun onHostResume() {
    if (!canRequestPackageInstalls()) {
      return
    }
    val filePath = updatePreferences().getString(PENDING_UPDATE_APK_PATH, null) ?: return
    val file = File(filePath)
    try {
      if (!file.exists() || file.length() <= 0L) {
        clearPendingUpdateApk()
        return
      }
      verifyDownloadedApkIdentity(file, checksumVerified = hasVerifiedChecksumSidecar(file))
      openPackageInstaller(file)
      clearPendingUpdateApk()
      Log.i(TAG, "Resumed pending Android APK installation after permission grant.")
    } catch (error: Throwable) {
      clearPendingUpdateApk()
      Log.e(TAG, "Pending Android APK installation could not be resumed: ${error.message}", error)
    }
  }

  override fun onHostPause() = Unit

  override fun onHostDestroy() = Unit

  private fun ensureStatusEmitterRunning() {
    if (statusEmitterJob?.isActive == true || listenerCount <= 0) {
      return
    }
    statusEmitterJob = scope.launch {
      pollVpnStatus(
        shouldContinue = { listenerCount > 0 },
        poll = {
          val status = currentVpnStatus()
          emitVpnStatusChanged(status)
          statusPollDelayMs(status)
        },
        onError = { error -> Log.w(TAG, "Native VPN status emitter failed: ${error.message}") },
        errorDelayMs = STATUS_POLL_ERROR_MS,
      )
    }
  }

  private fun stopStatusEmitter() {
    statusEmitterJob?.cancel()
    statusEmitterJob = null
  }

  private fun emitVpnStatusChanged(status: WritableMap, force: Boolean = false) {
    if (!force && listenerCount <= 0) {
      return
    }
    val statusSnapshot = Arguments.makeNativeMap(status.toHashMap())
    if (!force && lastEmittedVpnStatus?.let { writableMapsEqual(it, statusSnapshot) } == true) {
      return
    }
    lastEmittedVpnStatus = statusSnapshot
    if (listenerCount <= 0) {
      return
    }
    reactContext
      .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
      .emit(VPN_STATUS_CHANGED_EVENT, Arguments.makeNativeMap(statusSnapshot.toHashMap()))
  }

  private fun statusPollDelayMs(status: WritableMap): Long {
    return when (status.getString("state")) {
      "connected" -> CONNECTED_STATUS_POLL_MS
      "connecting", "disconnecting", "verifying", "degraded" -> TRANSITION_STATUS_POLL_MS
      else -> IDLE_STATUS_POLL_MS
    }
  }

  private fun writableMapsEqual(left: WritableMap, right: WritableMap): Boolean {
    return left.toHashMap() == right.toHashMap()
  }

  private suspend fun currentVpnStatus(): WritableMap =
    if (vlessController.isSelected()) vlessController.status().toVlessWritableMap()
    else controller.status().toWritableMap()

  private fun nextEngineRevision(awgWanted: Boolean?, promise: Promise): Long? = try {
    engineRevision.next(awgWanted)
  } catch (error: Throwable) {
    rejectVpnError(promise, "VPN_INTENT_STATE_FAILED", "VPN connection intent could not be recorded.", error)
    null
  }

  private fun org.json.JSONObject.toVlessWritableMap(): WritableMap = Arguments.createMap().also { result ->
    result.putString("transport", "vless")
    result.putString("state", optString("state", "error"))
    result.putString("connectionId", optString("connectionId"))
    result.putBoolean("connectionWanted", optBoolean("connectionWanted"))
    result.putBoolean("verified", optBoolean("verified"))
    result.putString("leakProtection", optString("leakProtection", "off"))
    result.putDouble("rxBytes", 0.0)
    result.putDouble("txBytes", 0.0)
    if (has("verificationEpochMillis")) result.putDouble("verificationEpochMillis", optDouble("verificationEpochMillis"))
    if (has("verificationReason")) result.putString("verificationReason", optString("verificationReason"))
    if (has("latencyMs")) result.putDouble("latencyMs", optDouble("latencyMs"))
  }

  private fun VpnConnectionState.toWritableMap(): WritableMap {
    val map = Arguments.createMap()
    when (this) {
      is VpnConnectionState.Connected -> {
        val hasTunnelActivity = VpnHandshakeVerifier.isVerified(traffic.latestHandshakeEpochMillis)
        map.putString("state", "connected")
        map.putDouble("rxBytes", traffic.rxBytes.toDouble())
        map.putDouble("txBytes", traffic.txBytes.toDouble())
        map.putDouble("latestHandshakeEpochMillis", traffic.latestHandshakeEpochMillis.toDouble())
        map.putString("leakProtection", this.leakProtection.wireValue)
        map.putBoolean("verified", hasTunnelActivity)
        if (!hasTunnelActivity) {
          map.putString("verificationReason", "handshake_pending")
        }
      }
      VpnConnectionState.Disconnected -> {
        map.putString("state", "disconnected")
        map.putDouble("rxBytes", 0.0)
        map.putDouble("txBytes", 0.0)
        map.putDouble("latestHandshakeEpochMillis", 0.0)
        map.putString("leakProtection", "off")
        map.putBoolean("verified", false)
      }
      VpnConnectionState.Blocking -> {
        map.putString("state", "error")
        map.putDouble("rxBytes", 0.0)
        map.putDouble("txBytes", 0.0)
        map.putDouble("latestHandshakeEpochMillis", 0.0)
        map.putString("leakProtection", "blocking")
        map.putBoolean("verified", false)
        map.putString("verificationReason", "endpoint_failed")
      }
      is VpnConnectionState.Transition -> {
        map.putString("state", this.state)
        map.putDouble("rxBytes", 0.0)
        map.putDouble("txBytes", 0.0)
        map.putDouble("latestHandshakeEpochMillis", 0.0)
        map.putString("leakProtection", this.leakProtection.wireValue)
        map.putBoolean("verified", false)
        map.putString("verificationReason", "handshake_pending")
      }
    }
    engineRevision.awgWanted()?.let { map.putBoolean("connectionWanted", it) }
    return map
  }

  private fun StoredWireGuardKeyPair.toWritableMap(): WritableMap {
    val map = Arguments.createMap()
    map.putString("privateKey", privateKey)
    map.putString("publicKey", publicKey)
    map.putInt("keyEpoch", keyEpoch)
    return map
  }

  private fun installedApplications(): com.facebook.react.bridge.WritableArray {
    val packageManager = reactContext.packageManager
    val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      packageManager.queryIntentActivities(launcherIntent, PackageManager.ResolveInfoFlags.of(0L))
    } else {
      @Suppress("DEPRECATION")
      packageManager.queryIntentActivities(launcherIntent, 0)
    }
    val result = Arguments.createArray()
    resolved
      .asSequence()
      .filter { it.activityInfo?.packageName != reactContext.packageName }
      .distinctBy { it.activityInfo.packageName }
      .map { info ->
        val label = info.loadLabel(packageManager).toString().trim()
        Triple(label.ifEmpty { info.activityInfo.packageName }, info.activityInfo.packageName, info.loadIcon(packageManager))
      }
      .sortedBy { it.first.lowercase() }
      .forEach { (label, packageName, icon) ->
        val item = Arguments.createMap()
        item.putString("label", label)
        item.putString("packageName", packageName)
        item.putString("iconDataUri", drawableDataUri(icon))
        result.pushMap(item)
      }
    return result
  }

  private fun drawableDataUri(drawable: android.graphics.drawable.Drawable): String {
    val size = (48 * reactContext.resources.displayMetrics.density).toInt().coerceIn(48, 144)
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    drawable.setBounds(0, 0, size, size)
    drawable.draw(canvas)
    val output = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
    bitmap.recycle()
    return "data:image/png;base64,${Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)}"
  }

  private fun rejectVpnError(promise: Promise, code: String, fallbackMessage: String, error: Throwable) {
    VpnErrorDispatcher.dispatch(
      code = code,
      fallbackMessage = fallbackMessage,
      error = error,
      log = { dispatchedCode, message, sanitizedError -> Log.e(TAG, "$dispatchedCode: $message", sanitizedError) },
      telemetry = { dispatchedCode, message, sanitizedError ->
        recordNonFatalVpnError(dispatchedCode, message, sanitizedError)
      },
      reject = { dispatchedCode, message, sanitizedError -> promise.reject(dispatchedCode, message, sanitizedError) },
    )
  }

  private fun recordNonFatalVpnError(code: String, message: String, error: Throwable) {
    // Promise/log delivery keeps the already-redacted boundary message. Bugsink
    // receives fixed diagnostic vocabulary only, never exception text or stacks.
    recordBugsinkVpnError(code)
  }

  private fun recordBugsinkVpnError(code: String) {
    try {
      val category = VpnLogRedaction.telemetryErrorCategory(code)
      val stage = VpnLogRedaction.telemetryErrorStage(code)
      Sentry.withScope { scope ->
        scope.setTag("vex_platform", "android")
        scope.setTag("vex_vpn_error_code", code)
        scope.setTag("vex_vpn_error_category", category)
        scope.setTag("vex_vpn_error_stage", stage)
        Sentry.captureException(VpnLogRedaction.telemetryThrowable(category, stage))
      }
    } catch (_: Throwable) {
      // Observability must never break VPN control flow.
    }
  }

  companion object {
    private const val REQUEST_VPN_PERMISSION = 7421
    private const val REQUEST_NOTIFICATION_PERMISSION = 5018
    private const val TAG = "VexVpn"
    private const val VPN_STATUS_CHANGED_EVENT = "vpn-status-changed"
    private const val IDLE_STATUS_POLL_MS = 7_500L
    private const val CONNECTED_STATUS_POLL_MS = 4_000L
    private const val TRANSITION_STATUS_POLL_MS = 1_500L
    private const val STATUS_POLL_ERROR_MS = 4_000L
    private const val DISCONNECT_HARD_RECOVERY_MS = VpnNetworkRecoveryTiming.DISCONNECT_HARD_RECOVERY_MS
    private const val CONNECT_HARD_RECOVERY_MS = VpnNetworkRecoveryTiming.CONNECT_HARD_RECOVERY_MS
    private const val NETWORK_RECOVERY_HARD_TIMEOUT_RETRY_MS = 5_000L
    private const val UPDATE_DOWNLOAD_CONNECT_TIMEOUT_MS = 30_000
    private const val UPDATE_DOWNLOAD_READ_TIMEOUT_MS = 60_000
    private const val UPDATE_PREFERENCES = "vex_android_update"
    private const val PENDING_UPDATE_APK_PATH = "pending_apk_path"
  }

  private data class ApkDownloadResult(
    val file: File,
    val sizeBytes: Long,
    val checksumSha256: String,
  )

  private data class ApkIdentity(
    val packageName: String,
    val signerDigests: Set<String>,
  )

  private fun downloadAndVerifyApk(downloadUrl: String, checksumSha256: String?): ApkDownloadResult {
    val normalizedUrl = downloadUrl.trim()
    val url = URL(normalizedUrl)
    if (url.protocol != "https") {
      throw IllegalArgumentException("Update APK URL must use HTTPS.")
    }

    val updatesDir = File(reactContext.cacheDir, "updates")
    if (!updatesDir.exists() && !updatesDir.mkdirs()) {
      throw IllegalStateException("Cannot create update cache directory.")
    }

    val output = File(updatesDir, "VEX-update.apk")
    val digest = MessageDigest.getInstance("SHA-256")
    var totalBytes = 0L

    val connection = url.openConnection().apply {
      connectTimeout = UPDATE_DOWNLOAD_CONNECT_TIMEOUT_MS
      readTimeout = UPDATE_DOWNLOAD_READ_TIMEOUT_MS
    }

    connection.getInputStream().use { input ->
      output.outputStream().use { fileOutput ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
          val read = input.read(buffer)
          if (read <= 0) break
          digest.update(buffer, 0, read)
          fileOutput.write(buffer, 0, read)
          totalBytes += read
        }
      }
    }

    if (totalBytes <= 0L) {
      output.delete()
      throw IllegalStateException("Downloaded APK is empty.")
    }

    val actualChecksum = digest.digest().joinToString("") { "%02x".format(it) }
    val expectedChecksum = checksumSha256?.trim().orEmpty()
    val checksumVerified = expectedChecksum.isNotEmpty() && actualChecksum.equals(expectedChecksum, ignoreCase = true)
    if (expectedChecksum.isNotEmpty() && !checksumVerified) {
      output.delete()
      checksumSidecar(output).delete()
      throw IllegalStateException("Downloaded APK checksum mismatch.")
    }

    if (checksumVerified) {
      checksumSidecar(output).writeText(actualChecksum)
    } else {
      checksumSidecar(output).delete()
    }

    verifyDownloadedApkIdentity(output, checksumVerified = checksumVerified)
    return ApkDownloadResult(output, totalBytes, actualChecksum)
  }

  private fun verifyDownloadedApkIdentity(apkFile: File, checksumVerified: Boolean = false) {
    val installed = readInstalledApkIdentity()
    val archive = readArchiveApkIdentity(apkFile)

    if (archive == null) {
      if (checksumVerified) {
        Log.w(TAG, "Downloaded APK metadata is unavailable; SHA-256 checksum matched manifest.")
        return
      }
      apkFile.delete()
      throw IllegalStateException("Не удалось прочитать метаданные загруженного APK.")
    }

    if (archive.packageName != installed.packageName) {
      apkFile.delete()
      throw IllegalStateException("Загруженный APK принадлежит другому приложению.")
    }
    if (archive.signerDigests.isEmpty()) {
      if (checksumVerified) {
        Log.w(TAG, "Downloaded APK signer metadata is unavailable; SHA-256 checksum matched manifest.")
        return
      }
      apkFile.delete()
      throw IllegalStateException("Не удалось прочитать подпись загруженного APK.")
    }
    if (installed.signerDigests.isEmpty()) {
      apkFile.delete()
      throw IllegalStateException("Не удалось прочитать подпись установленного VEX.")
    }
    if (archive.signerDigests.intersect(installed.signerDigests).isEmpty()) {
      apkFile.delete()
      throw IllegalStateException("Подпись APK не совпадает с установленной версией VEX.")
    }
  }

  private fun readInstalledApkIdentity(): ApkIdentity {
    val packageManager = reactContext.packageManager
    val packageName = reactContext.packageName
    val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(packageSigningFlags()))
    } else {
      @Suppress("DEPRECATION")
      packageManager.getPackageInfo(packageName, packageSigningFlags().toInt())
    }
    return ApkIdentity(packageInfo.packageName.orEmpty(), signerDigests(packageInfo))
  }

  private fun readArchiveApkIdentity(apkFile: File): ApkIdentity? {
    val packageManager = reactContext.packageManager
    val packageInfo = archivePackageInfo(packageManager, apkFile, packageSigningFlags())
      ?: archivePackageInfo(packageManager, apkFile, legacyPackageSigningFlags())
      ?: return null
    val signerDigests = signerDigests(packageInfo).ifEmpty {
      archivePackageInfo(packageManager, apkFile, legacyPackageSigningFlags())
        ?.let(::signerDigests)
        .orEmpty()
    }
    return ApkIdentity(packageInfo.packageName.orEmpty(), signerDigests)
  }

  private fun archivePackageInfo(packageManager: PackageManager, apkFile: File, flags: Long): PackageInfo? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      packageManager.getPackageArchiveInfo(apkFile.absolutePath, PackageManager.PackageInfoFlags.of(flags))
    } else {
      @Suppress("DEPRECATION")
      packageManager.getPackageArchiveInfo(apkFile.absolutePath, flags.toInt())
    }
  }

  private fun signerDigests(packageInfo: PackageInfo): Set<String> {
    val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      val signingInfo = packageInfo.signingInfo ?: return emptySet()
      if (signingInfo.hasMultipleSigners()) {
        signingInfo.apkContentsSigners
      } else {
        signingInfo.signingCertificateHistory
      }
    } else {
      @Suppress("DEPRECATION")
      packageInfo.signatures ?: emptyArray()
    }

    return signatures
      .asSequence()
      .map(Signature::toByteArray)
      .map(::sha256Hex)
      .filter(String::isNotBlank)
      .toSet()
  }

  private fun canRequestPackageInstalls(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return true
    }
    return try {
      reactContext.packageManager.canRequestPackageInstalls()
    } catch (_: SecurityException) {
      // Local/dev variants deliberately omit REQUEST_INSTALL_PACKAGES. They must
      // treat OTA installation as unavailable rather than crash on resume.
      false
    }
  }

  private fun openUnknownSourcesSettings() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return
    }
    val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
      data = Uri.parse("package:${reactContext.packageName}")
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    reactContext.startActivity(intent)
  }

  private fun openPackageInstaller(file: File) {
    val uri = FileProvider.getUriForFile(
      reactContext,
      "${reactContext.packageName}.fileprovider",
      file,
    )
    val intent = Intent(Intent.ACTION_VIEW).apply {
      setDataAndType(uri, "application/vnd.android.package-archive")
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    check(intent.resolveActivity(reactContext.packageManager) != null) {
      "На устройстве не найден системный установщик APK."
    }
    reactContext.startActivity(intent)
  }

  private fun rememberPendingUpdateApk(file: File) {
    updatePreferences().edit().putString(PENDING_UPDATE_APK_PATH, file.absolutePath).apply()
  }

  private fun clearPendingUpdateApk() {
    updatePreferences().edit().remove(PENDING_UPDATE_APK_PATH).apply()
  }

  private fun updatePreferences() = reactContext.getSharedPreferences(UPDATE_PREFERENCES, 0)

  private fun updateInstallResult(status: String): WritableMap {
    return Arguments.createMap().apply {
      putString("status", status)
    }
  }

  private fun packageSigningFlags(): Long {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      PackageManager.GET_SIGNING_CERTIFICATES.toLong()
    } else {
      @Suppress("DEPRECATION")
      PackageManager.GET_SIGNATURES.toLong()
    }
  }

  private fun legacyPackageSigningFlags(): Long {
    @Suppress("DEPRECATION")
    return PackageManager.GET_SIGNATURES.toLong()
  }

  private fun sha256Hex(value: ByteArray): String {
    return MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
  }

  private fun hasVerifiedChecksumSidecar(apkFile: File): Boolean {
    val sidecar = checksumSidecar(apkFile)
    if (!sidecar.isFile) {
      return false
    }
    val expected = sidecar.readText().trim()
    if (!expected.matches(Regex("^[a-fA-F0-9]{64}$"))) {
      sidecar.delete()
      return false
    }
    val actual = sha256File(apkFile)
    return expected.equals(actual, ignoreCase = true)
  }

  private fun sha256File(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
      val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
      while (true) {
        val bytesRead = input.read(buffer)
        if (bytesRead <= 0) {
          break
        }
        digest.update(buffer, 0, bytesRead)
      }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
  }

  private fun checksumSidecar(apkFile: File): File {
    return File(apkFile.parentFile, "${apkFile.name}.sha256")
  }
}
