package com.vexguard.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Local-build-only entry point for black-box VPN and kill-switch verification. */
class VexVpnTestReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    when (intent.action) {
      ACTION_START_BLOCKER -> VexLeakBlockerService.start(context)
      ACTION_STOP_BLOCKER -> VexLeakBlockerService.stop(context)
    }
  }

  companion object {
    private const val ACTION_START_BLOCKER = "com.vexguard.app.dev.TEST_START_BLOCKER"
    private const val ACTION_STOP_BLOCKER = "com.vexguard.app.dev.TEST_STOP_BLOCKER"
  }
}
