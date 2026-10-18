package com.vexguard.app.vpn

import android.content.Context
import org.amnezia.awg.config.Config
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Public, signed routing data only. Go re-verifies every cache reuse. */
internal class NativeRoutingPolicyStore(context: Context) {
  private val file = File(context.filesDir, "routing-policy-v2.json")

  fun parameters(raw: String, config: Config): String {
    require(raw.length <= 2 * 1024 * 1024) { "Routing parameters are too large." }
    val value = JSONObject(raw)
    require(value.optString("mode") in setOf("full_tunnel", "all_except_ru")) { "Routing mode is invalid." }
    // Source addresses come from the admitted AWG interface, not bridge hints.
    value.put("addresses", JSONArray(config.`interface`.addresses.map { it.toString() }))
    value.put("dns", JSONArray(config.`interface`.dnsServers.map { it.hostAddress }))
    val cached = runCatching {
        if (file.length() > 2 * 1024 * 1024) null else JSONObject(file.readText())
      }.getOrNull()
    value.remove("previous_authorization")
    if (cached != null) value.put("previous_authorization", cached)
    if (value.optString("mode") == "all_except_ru" && value.optJSONObject("authorization") == null) {
      if (cached != null) value.put("authorization", cached)
    }
    return value.toString()
  }

  fun saveAuthorization(authorization: String) {
    require(authorization.length <= 2 * 1024 * 1024)
    val temporary = File(file.parentFile, "routing-policy-v2.pending")
    temporary.writeText(authorization)
    require(temporary.renameTo(file)) { "Routing cache could not be committed." }
  }
}
