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
    val message = VpnLogRedaction.redact(
      error.message?.takeIf { it.isNotBlank() }
        ?: error.cause?.message?.takeIf { it.isNotBlank() }
        ?: "${error::class.java.simpleName}: $fallbackMessage",
    )
    log(code, message, VpnLogRedaction.sanitizedThrowable(message))
    telemetry(code, message, VpnLogRedaction.sanitizedThrowable(message))
    reject(code, message, VpnLogRedaction.sanitizedThrowable(message))
  }
}
