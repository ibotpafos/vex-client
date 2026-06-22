package com.vexguard.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.vexguard.app.MainActivity
import java.io.FileInputStream
import java.util.concurrent.atomic.AtomicBoolean

class VexLeakBlockerService : VpnService() {
  private var tunnel: ParcelFileDescriptor? = null
  private var drainThread: Thread? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      stopBlocking()
      stopSelf()
      return START_NOT_STICKY
    }

    startForeground(NOTIFICATION_ID, blockerNotification())
    startBlocking()
    return START_STICKY
  }

  override fun onDestroy() {
    stopBlocking()
    super.onDestroy()
  }

  override fun onRevoke() {
    stopBlocking()
    stopSelf()
    super.onRevoke()
  }

  private fun startBlocking() {
    if (tunnel != null) {
      active.set(true)
      return
    }

    tunnel = Builder()
      .setSession("VEX AntiDetect")
      .addAddress("10.255.255.1", 32)
      .addRoute("0.0.0.0", 0)
      .addAddress("fd00:255:255::1", 128)
      .addRoute("::", 0)
      .setBlocking(false)
      .establish()

    active.set(tunnel != null)
    val descriptor = tunnel?.fileDescriptor ?: return
    drainThread = Thread {
      val buffer = ByteArray(32_768)
      try {
        FileInputStream(descriptor).use { input ->
          while (!Thread.currentThread().isInterrupted) {
            if (input.read(buffer) < 0) {
              break
            }
          }
        }
      } catch (_: Throwable) {
      }
    }.apply {
      name = "vex-leak-blocker"
      isDaemon = true
      start()
    }
  }

  private fun stopBlocking() {
    active.set(false)
    drainThread?.interrupt()
    drainThread = null
    try {
      tunnel?.close()
    } catch (_: Throwable) {
    }
    tunnel = null
  }

  private fun blockerNotification(): Notification {
    val manager = getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      manager.createNotificationChannel(
        NotificationChannel(
          CHANNEL_ID,
          "VEX AntiDetect",
          NotificationManager.IMPORTANCE_LOW,
        ),
      )
    }

    val pendingIntent = PendingIntent.getActivity(
      this,
      0,
      Intent(this, MainActivity::class.java),
      PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      @Suppress("DEPRECATION")
      Notification.Builder(this)
    }
    return builder
      .setContentTitle("VEX AntiDetect")
      .setContentText("Интернет заблокирован, чтобы не раскрыть реальный IP.")
      .setSmallIcon(android.R.drawable.stat_sys_warning)
      .setContentIntent(pendingIntent)
      .setOngoing(true)
      .build()
  }

  companion object {
    private const val ACTION_STOP = "com.vexguard.app.vpn.STOP_LEAK_BLOCKER"
    private const val CHANNEL_ID = "vex_antileak"
    private const val NOTIFICATION_ID = 9173
    private val active = AtomicBoolean(false)

    fun start(context: Context) {
      context.startService(Intent(context, VexLeakBlockerService::class.java))
    }

    fun stop(context: Context) {
      context.startService(Intent(context, VexLeakBlockerService::class.java).setAction(ACTION_STOP))
    }

    fun isActive(): Boolean = active.get()
  }
}
