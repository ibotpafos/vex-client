package com.vexguard.app.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.vexguard.app.MainActivity
import com.vexguard.app.R
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VexFirebaseMessagingService : FirebaseMessagingService() {
  override fun onNewToken(token: String) {
    Log.i(TAG, "FCM token refreshed.")
  }

  override fun onMessageReceived(message: RemoteMessage) {
    val type = message.data["type"] ?: "unknown"
    Log.i(TAG, "FCM message received type=$type")
    showNotification(message)
  }

  private fun showNotification(message: RemoteMessage) {
    createNotificationChannel()

    val intent = Intent(this, MainActivity::class.java).apply {
      addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
    val pendingIntent = PendingIntent.getActivity(
      this,
      0,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    val title = message.notification?.title
      ?: message.data["title"]
      ?: "VEX VPN"
    val body = message.notification?.body
      ?: message.data["body"]
      ?: "Откройте VEX, чтобы применить обновление."

    val notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.mipmap.ic_launcher_monochrome)
      .setContentTitle(title)
      .setContentText(body)
      .setStyle(NotificationCompat.BigTextStyle().bigText(body))
      .setContentIntent(pendingIntent)
      .setAutoCancel(true)
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .build()

    try {
      NotificationManagerCompat.from(this).notify(notificationID(message), notification)
    } catch (error: SecurityException) {
      Log.w(TAG, "Notification permission is not granted: ${error.message}")
    }
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return
    }
    val channel = NotificationChannel(
      CHANNEL_ID,
      "VEX VPN",
      NotificationManager.IMPORTANCE_HIGH,
    ).apply {
      description = "VPN profile and account updates"
    }
    val manager = getSystemService(NotificationManager::class.java)
    manager.createNotificationChannel(channel)
  }

  private fun notificationID(message: RemoteMessage): Int {
    val stableID = message.data["device_id"] ?: message.messageId ?: System.currentTimeMillis().toString()
    return stableID.hashCode()
  }

  companion object {
    private const val CHANNEL_ID = "vex_updates"
    private const val TAG = "VexFirebaseMessaging"
  }
}
