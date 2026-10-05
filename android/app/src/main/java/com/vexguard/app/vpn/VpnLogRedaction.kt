package com.vexguard.app.vpn

internal object VpnLogRedaction {
  private val sensitiveAssignment = Regex(
    "(?i)\\b(PrivateKey|PresharedKey|HeaderProtectionKey)\\s*=\\s*([^\\s\\r\\n]+)",
  )

  fun redact(value: String): String = sensitiveAssignment.replace(value, "${'$'}1 = [REDACTED]")

  fun sanitizedThrowable(message: String): Throwable = IllegalStateException(message)

  /** Only fixed vocabulary reaches Bugsink tags or the captured exception. */
  fun telemetryErrorCategory(code: String): String = when (code) {
    "VPN_CONFIG_INVALID" -> "configuration"
    "VPN_PERMISSION_REQUIRED", "VPN_PERMISSION_DENIED", "VPN_PERMISSION_IN_PROGRESS" -> "permission"
    "VPN_CONNECT_FAILED", "VPN_DISCONNECT_FAILED", "VPN_STATUS_FAILED" -> "connection"
    "VPN_KEYPAIR_FAILED", "VPN_KEYPAIR_GENERATE_FAILED", "VPN_KEYPAIR_REPLACE_FAILED", "VPN_KEYPAIR_RESET_FAILED" -> "key_management"
    "VPN_APPLICATIONS_FAILED", "VPN_SETTINGS_FAILED", "VPN_LATENCY_FAILED", "VPN_DIAGNOSTICS_FAILED" -> "platform"
    else -> "unknown"
  }

  fun telemetryErrorStage(code: String): String = when (code) {
    "VPN_CONFIG_INVALID" -> "configuration"
    "VPN_PERMISSION_REQUIRED", "VPN_PERMISSION_DENIED", "VPN_PERMISSION_IN_PROGRESS" -> "permission"
    "VPN_CONNECT_FAILED" -> "connect"
    "VPN_DISCONNECT_FAILED" -> "disconnect"
    "VPN_STATUS_FAILED" -> "status"
    "VPN_KEYPAIR_FAILED", "VPN_KEYPAIR_GENERATE_FAILED", "VPN_KEYPAIR_REPLACE_FAILED", "VPN_KEYPAIR_RESET_FAILED" -> "keypair"
    "VPN_APPLICATIONS_FAILED" -> "applications"
    "VPN_SETTINGS_FAILED" -> "settings"
    "VPN_LATENCY_FAILED" -> "latency"
    "VPN_DIAGNOSTICS_FAILED" -> "diagnostics"
    else -> "unknown"
  }

  fun telemetryThrowable(category: String, stage: String): Throwable =
    IllegalStateException("VPN $category failure at $stage")
}
