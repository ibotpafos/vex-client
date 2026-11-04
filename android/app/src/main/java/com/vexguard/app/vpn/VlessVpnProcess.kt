package com.vexguard.app.vpn

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Process

/** Must not reference React Native, AWG, Sentry or any generated Go class. */
object VlessVpnProcess {
  const val SUFFIX = ":vless"
  fun isVless(context: Context): Boolean {
    val name = if (Build.VERSION.SDK_INT >= 28) Application.getProcessName() else {
      val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
      manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
    }
    return name == context.packageName + SUFFIX
  }
}
