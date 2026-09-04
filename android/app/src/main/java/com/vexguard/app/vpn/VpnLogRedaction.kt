package com.vexguard.app.vpn

internal object VpnLogRedaction {
  private val sensitiveAssignment = Regex(
    "(?i)\\b(PrivateKey|PresharedKey|HeaderProtectionKey)\\s*=\\s*([^\\s\\r\\n]+)",
  )

  fun redact(value: String): String = sensitiveAssignment.replace(value, "${'$'}1 = [REDACTED]")

  fun sanitizedThrowable(message: String): Throwable = IllegalStateException(message)
}
