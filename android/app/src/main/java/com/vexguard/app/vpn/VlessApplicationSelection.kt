package com.vexguard.app.vpn

import android.content.Context

internal object VlessApplicationSelection {
  fun admit(context: Context, packages: List<String>, selectedOnly: Boolean): VlessApplicationPolicy.Selection =
    VlessApplicationPolicy.admit(packages, selectedOnly, context.packageName) { name ->
      runCatching {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(name, 0)
        true
      }.getOrDefault(false)
    }
}
