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
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableArray
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
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.URL
import java.security.MessageDigest

class VexVpnModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  private val controller = WireGuardController(reactContext)
  private val wireGuardKeyStore = WireGuardKeyStore(reactContext)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
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
        promise.resolve(true)
      } else {
        promise.reject("VPN_PERMISSION_DENIED", "Android VPN permission was denied.")
      }
    }
  }

  init {
    reactContext.addActivityEventListener(activityEventListener)
  }

  override fun getName(): String = "VexVpn"

  @ReactMethod
  fun needsPermission(promise: Promise) {
    promise.resolve(controller.needsPermission())
  }

  @ReactMethod
  fun requestPermission(promise: Promise) {
    val intent = VpnService.prepare(reactContext)
    if (intent == null) {
      promise.resolve(true)
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
  ) {
    scope.launch {
      try {
        val status = controller.connect(
          wgQuickConfig,
          antiLeakEnabled,
          routeOnlySelectedApplications,
          selectedApplications,
        ).toWritableMap()
        emitVpnStatusChanged(status, force = true)
        promise.resolve(status)
      } catch (error: VpnPermissionRequiredException) {
        rejectVpnError(promise, "VPN_PERMISSION_REQUIRED", "Android VPN permission is required.", error)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_CONNECT_FAILED", "VPN connection failed.", error)
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
    val recoveryHandler = Handler(Looper.getMainLooper())
    val hardRecovery = Runnable {
      Log.e(TAG, "VPN disconnect exceeded ${DISCONNECT_HARD_RECOVERY_MS}ms; terminating the app process to release Android VPN descriptors.")
      VexLeakBlockerService.stop(reactContext)
      android.os.Process.killProcess(android.os.Process.myPid())
    }
    if (releaseAntiLeak) {
      recoveryHandler.postDelayed(hardRecovery, DISCONNECT_HARD_RECOVERY_MS)
    }
    scope.launch {
      try {
        val status = controller.disconnect(releaseAntiLeak).toWritableMap()
        emitVpnStatusChanged(status, force = true)
        promise.resolve(status)
      } catch (error: Throwable) {
        rejectVpnError(promise, "VPN_DISCONNECT_FAILED", "VPN disconnect failed.", error)
      } finally {
        recoveryHandler.removeCallbacks(hardRecovery)
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
  fun status(promise: Promise) {
    scope.launch {
      try {
        val status = controller.status().toWritableMap()
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
        promise.resolve(controller.measureEndpointLatency(endpoint))
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
        event.putMap("status", controller.status().toWritableMap())
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
        openUnknownSourcesSettings()
        promise.resolve(updateInstallResult("install_permission_required"))
        return
      }

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
      if (intent.resolveActivity(reactContext.packageManager) == null) {
        promise.reject("UPDATE_INSTALLER_NOT_AVAILABLE", "На устройстве не найден системный установщик APK.")
        return
      }
      reactContext.startActivity(intent)
      promise.resolve(updateInstallResult("installer_started"))
    } catch (error: Throwable) {
      promise.reject("UPDATE_INSTALL_FAILED", error.message ?: "Не удалось открыть установщик APK.", error)
    }
  }

  override fun invalidate() {
    pendingPermissionPromise?.reject("MODULE_INVALIDATED", "VexVpn module was invalidated.")
    pendingPermissionPromise = null
    stopStatusEmitter()
    reactContext.removeActivityEventListener(activityEventListener)
    scope.cancel()
    super.invalidate()
  }

  private fun ensureStatusEmitterRunning() {
    if (statusEmitterJob?.isActive == true || listenerCount <= 0) {
      return
    }
    statusEmitterJob = scope.launch {
      while (isActive && listenerCount > 0) {
        try {
          val status = controller.status().toWritableMap()
          emitVpnStatusChanged(status)
          delay(statusPollDelayMs(status))
        } catch (error: Throwable) {
          Log.w(TAG, "Native VPN status emitter failed: ${error.message}")
          delay(STATUS_POLL_ERROR_MS)
        }
      }
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

  private fun VpnConnectionState.toWritableMap(): WritableMap {
    val map = Arguments.createMap()
    when (this) {
      is VpnConnectionState.Connected -> {
        val hasTunnelActivity = traffic.latestHandshakeEpochMillis > 0L || traffic.rxBytes > 0L || traffic.txBytes > 0L
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
    val message = error.message?.takeIf { it.isNotBlank() }
      ?: error.cause?.message?.takeIf { it.isNotBlank() }
      ?: "${error::class.java.simpleName}: $fallbackMessage"
    Log.e(TAG, "$code: $message", error)
    recordNonFatalVpnError(code, message, error)
    promise.reject(code, message, error)
  }

  private fun recordNonFatalVpnError(code: String, message: String, error: Throwable) {
    recordBugsinkVpnError(code, message, error)
  }

  private fun recordBugsinkVpnError(code: String, message: String, error: Throwable) {
    try {
      Sentry.withScope { scope ->
        scope.setTag("vex_platform", "android")
        scope.setTag("vex_vpn_error_code", code)
        scope.setExtra("vex_vpn_error_message", message)
        Sentry.captureException(error)
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
    private const val DISCONNECT_HARD_RECOVERY_MS = 8_000L
    private const val UPDATE_DOWNLOAD_CONNECT_TIMEOUT_MS = 30_000
    private const val UPDATE_DOWNLOAD_READ_TIMEOUT_MS = 60_000
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
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.O || reactContext.packageManager.canRequestPackageInstalls()
  }

  private fun openUnknownSourcesSettings() {
    val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
      data = Uri.parse("package:${reactContext.packageName}")
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    reactContext.startActivity(intent)
  }

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
