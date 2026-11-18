package com.vexguard.app.vpn

import android.app.Application
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import org.junit.runner.JUnitCore
import org.junit.runner.notification.Failure

// Bounded diagnostics for this fixed, fixture-only suite; never dump app state/logs.
internal fun nativeHttpFailureDetails(failure: Failure): String {
  val error = failure.exception
  val message = error.message.orEmpty().replace('\n', ' ').replace('\r', ' ').take(256)
  val frames = error.stackTrace.take(8).joinToString(" | ") { it.toString().take(160) }
  return "${failure.testHeader.take(160)}: ${error.javaClass.simpleName} $message | $frames".take(1536)
}

/** Test APK only. Never starts MainApplication, React, activities or VPN services. */
class NativeHttpInstrumentation : Instrumentation() {
  private fun guard(context: Context) {
    check(context.packageName == "com.vexguard.app.sdk58preview") { "EXACT_PREVIEW_REQUIRED" }
    check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) { "DEBUGGABLE_REQUIRED" }
    check(Build.VERSION.SDK_INT >= 24) { "APP_MIN_API_24_REQUIRED" }
    // Providers run before Instrumentation.onCreate; replacing Application alone
    // cannot suppress Firebase/Sentry. Operator must disable preview providers.
    val pm = context.packageManager
    val providers = pm.getPackageInfo(context.packageName,
      PackageManager.GET_PROVIDERS or PackageManager.GET_DISABLED_COMPONENTS).providers.orEmpty()
    check(providers.none { provider ->
      when (pm.getComponentEnabledSetting(ComponentName(context.packageName, provider.name))) {
        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> provider.enabled
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER,
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED -> false
        else -> true
      }
    }) { "ENABLED_TARGET_PROVIDER_FORBIDDEN" }
  }

  override fun newApplication(cl: ClassLoader, className: String, context: Context): Application {
    guard(context)
    return super.newApplication(cl, Application::class.java.name, context)
  }

  override fun onCreate(arguments: Bundle?) {
    guard(targetContext)
    super.onCreate(arguments)
    start()
  }

  override fun onStart() {
    val report = Bundle()
    try {
      guard(targetContext)
      val result = JUnitCore().run(ApiHttpSafetyTest::class.java, ApiRecoveryPolicyTest::class.java,
        ApiRecoveryTransportAdmissionTest::class.java)
      check(result.runCount == 21 && result.ignoreCount == 0 && result.wasSuccessful()) {
        "tests=${result.runCount} failures=${result.failureCount} ignored=${result.ignoreCount} " +
          result.failures.take(3).joinToString { nativeHttpFailureDetails(it) }
      }
      report.putString("stream", "\nNATIVE_HTTP_OK tests=21 failures=0\n")
      finish(-1, report)
    } catch (error: Throwable) {
      report.putString("stream", "\nNATIVE_HTTP_FAIL ${error.javaClass.simpleName}: ${error.message.orEmpty().take(4096)}\n")
      finish(0, report)
    }
  }
  // TODO: Physical first-party JS/native ABI mutation send-count remains unproven;
  // loopback helper tests and pre-client admission negatives do not establish it.
}
