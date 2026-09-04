package com.vexguard.app.vpn

import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.vexguard.app.R
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Google-owned account picker; no WebView, VEX website or persistent Google token. */
class VexGoogleAuthModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val inFlight = AtomicBoolean(false)
  override fun getName() = "VexGoogleAuth"

  @ReactMethod
  fun signIn(promise: Promise) {
    if (!inFlight.compareAndSet(false, true)) {
      promise.reject("GOOGLE_SIGN_IN_BUSY", "Google sign-in is already open")
      return
    }
    scope.launch {
      try {
        val activity = reactApplicationContext.currentActivity
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
          promise.reject("GOOGLE_SIGN_IN_NO_ACTIVITY", "Open VEX before signing in")
          return@launch
        }
        // This PUBLIC OAuth web client ID is the audience accepted by the VEX API.
        val option = GetSignInWithGoogleOption.Builder(
          reactApplicationContext.getString(R.string.vex_google_server_client_id)
        ).build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val credential = CredentialManager.create(reactApplicationContext)
          .getCredential(context = activity, request = request).credential
        if (credential !is CustomCredential ||
          credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
          promise.reject("GOOGLE_SIGN_IN_INVALID", "Unexpected Google credential")
          return@launch
        }
        val idToken = GoogleIdTokenCredential.createFrom(credential.data).idToken
        if (idToken.isBlank()) {
          promise.reject("GOOGLE_SIGN_IN_INVALID", "Empty Google credential")
        } else {
          promise.resolve(idToken)
        }
      } catch (_: GetCredentialCancellationException) {
        promise.reject("GOOGLE_SIGN_IN_CANCELLED", "Google sign-in cancelled")
      } catch (error: CancellationException) {
        promise.reject("GOOGLE_SIGN_IN_CANCELLED", "Google sign-in cancelled")
        throw error
      } catch (_: Exception) {
        // Never forward provider exceptions/data to JS logs or diagnostics.
        promise.reject("GOOGLE_SIGN_IN_FAILED", "Google sign-in failed")
      } finally {
        inFlight.set(false)
      }
    }
  }

  @ReactMethod
  fun clearCredentialState(promise: Promise) {
    scope.launch {
      try {
        CredentialManager.create(reactApplicationContext)
          .clearCredentialState(ClearCredentialStateRequest())
        promise.resolve(null)
      } catch (error: CancellationException) {
        promise.reject("GOOGLE_SIGN_OUT_CANCELLED", "Google sign-out cancelled")
        throw error
      } catch (_: Exception) {
        promise.reject("GOOGLE_SIGN_OUT_FAILED", "Google sign-out failed")
      }
    }
  }

  override fun invalidate() {
    scope.cancel()
    super.invalidate()
  }
}
