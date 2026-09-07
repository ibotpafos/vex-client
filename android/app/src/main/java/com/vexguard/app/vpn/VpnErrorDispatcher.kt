package com.vexguard.app.vpn

/** Production error boundary shared by Android logging, telemetry, and React Native. */
internal object VpnErrorDispatcher {
  fun dispatch(
    code: String,
    fallbackMessage: String,
    error: Throwable,
    log: (String, String, Throwable) -> Unit,
    telemetry: (String, String, Throwable) -> Unit,
    reject: (String, String, Throwable) -> Unit,
  ) {
    val boundaryCode = if (error is AwgConfigValidationException) "VPN_CONFIG_INVALID" else code
    val message = VpnLogRedaction.redact(
      error.message?.takeIf { it.isNotBlank() }
        ?: error.cause?.message?.takeIf { it.isNotBlank() }
        ?: "${error::class.java.simpleName}: $fallbackMessage",
    )
    log(boundaryCode, message, VpnLogRedaction.sanitizedThrowable(message))
    telemetry(boundaryCode, message, VpnLogRedaction.sanitizedThrowable(message))
    reject(boundaryCode, message, VpnLogRedaction.sanitizedThrowable(message))
  }
}
