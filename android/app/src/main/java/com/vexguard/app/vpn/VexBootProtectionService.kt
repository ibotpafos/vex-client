package com.vexguard.app.vpn

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.Intent

/**
 * The sole system Always-on entry point. Capture first, without loading React,
 * credentials, a cached peer, or any network dependency. Android's optional
 * "Block connections without VPN" closes the interval before this TUN exists
 * and protects service death. Opening VEX can replace it with a fresh tunnel.
 *
 * Its separate process must never share the controller's in-process blocker
 * flag: handoff/revoke of this TUN must not mark the new native tunnel blocked.
 */
class VexBootProtectionService : VexLeakBlockerService() {
  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
    // A system restart has no per-app policy yet: capture all ordinary apps.
    // Never restore a previous account's selected applications or private key.
    super.onStartCommand(null, flags, startId)
}

internal fun isBootProtectionProcess(context: Context): Boolean {
  if (android.os.Build.VERSION.SDK_INT >= 28) {
    return Application.getProcessName() == context.packageName + ":boot_protection"
  }
  val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
  return manager.runningAppProcesses?.any {
    it.pid == android.os.Process.myPid() && it.processName == context.packageName + ":boot_protection"
  } == true
}
