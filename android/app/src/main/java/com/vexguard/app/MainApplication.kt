package com.vexguard.app

import android.app.Application
import android.content.res.Configuration

import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.ReactPackage
import com.facebook.react.ReactHost
import com.facebook.react.common.ReleaseLevel
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint
import com.vexguard.app.vpn.VexVpnPackage
import io.sentry.Sentry
import io.sentry.android.core.SentryAndroid

import expo.modules.ApplicationLifecycleDispatcher
import expo.modules.ExpoReactHostFactory

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    ExpoReactHostFactory.getDefaultReactHost(
      context = applicationContext,
      packageList =
        PackageList(this).packages.apply {
          // Packages that cannot be autolinked yet can be added manually here, for example:
          // add(MyReactNativePackage())
          add(VexVpnPackage())
        }
    )
  }

  override fun onCreate() {
    super.onCreate()
    DefaultNewArchitectureEntryPoint.releaseLevel = try {
      ReleaseLevel.valueOf(BuildConfig.REACT_NATIVE_RELEASE_LEVEL.uppercase())
    } catch (e: IllegalArgumentException) {
      ReleaseLevel.STABLE
    }
    loadReactNative(this)
    configureCrashReporting()
    ApplicationLifecycleDispatcher.onApplicationCreate(this)
  }

  override fun onConfigurationChanged(newConfig: Configuration) {
    super.onConfigurationChanged(newConfig)
    ApplicationLifecycleDispatcher.onConfigurationChanged(this, newConfig)
  }

  private fun configureCrashReporting() {
    configureSentry()
  }

  private fun configureSentry() {
    val dsn = BuildConfig.SENTRY_DSN.trim()
    if (dsn.isEmpty()) {
      return
    }

    try {
      SentryAndroid.init(this) { options ->
        options.dsn = dsn
        options.environment = BuildConfig.SENTRY_ENVIRONMENT.ifBlank { null }
        options.release = BuildConfig.SENTRY_RELEASE.ifBlank { null }
        options.tracesSampleRate = 0.0
      }
      Sentry.configureScope { scope ->
        scope.setTag("react_native_new_arch_enabled", BuildConfig.IS_NEW_ARCHITECTURE_ENABLED.toString())
        scope.setTag("react_native_release_level", BuildConfig.REACT_NATIVE_RELEASE_LEVEL)
        scope.setTag("vex_platform", "android")
      }
    } catch (_: Throwable) {
      // Sentry/Bugsink must not block app startup when observability is unavailable.
    }
  }

}
