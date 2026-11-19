package com.vexguard.app.vpn

import org.json.JSONObject

/** A withdrawn intent cannot inherit a connected indicator from a late RPC. */
internal object VlessStatusAuthority {
  fun withdrawn(value: JSONObject, holdCapture: Boolean): JSONObject {
    value.put("connectionWanted", false).put("verified", false)
    value.remove("verificationEpochMillis")
    value.remove("latencyMs")
    val captureReported = value.optString("leakProtection") in setOf("armed", "blocking")
    if (holdCapture && captureReported) value.put("state", "error")
    else value.put("state", "disconnected").put("leakProtection", "off")
    return value
  }
}
