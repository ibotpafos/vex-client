package com.vexguard.app.vpn

import org.json.JSONArray
import org.json.JSONObject

/** Admit immutable server transport settings; the client alone owns TUN/DNS/routing. */
internal object VlessRuntimeConfig {
  const val MAX_CONFIG_BYTES = 256 * 1024
  const val TUN_ADDRESS = "10.253.20.1"
  const val TUN_DNS = "10.253.20.2"
  const val TUN_IPV6 = "fd00:253:20::1"
  const val MTU = 1280
  const val HEALTH_HOST = "vexguard.app"
  const val HEALTH_PATH = "/v1/app/remote-config"
  private const val OUTBOUND_TAG = "vex-vless"

  fun admit(config: String, routing: String): JSONObject = try {
    admitChecked(config, routing)
  } catch (_: Exception) {
    // JSON parser diagnostics may quote the original credential-bearing input.
    throw IllegalArgumentException("VLESS configuration or routing policy is unsupported.")
  }

  private fun admitChecked(config: String, routing: String): JSONObject {
    require(config.toByteArray(Charsets.UTF_8).size in 1..MAX_CONFIG_BYTES) { "VLESS configuration size is invalid." }
    require(routing.toByteArray(Charsets.UTF_8).size <= MAX_CONFIG_BYTES) { "VLESS routing parameters are too large." }
    if (routing.isNotBlank()) require(JSONObject(routing).optString("mode") == "full_tunnel") { "VLESS currently supports full tunnel routing only." }
    val root = JSONObject(config)
    val outbounds = root.optJSONArray("outbounds") ?: throw IllegalArgumentException("VLESS outbound is missing.")
    require(outbounds.length() == 1) { "VLESS requires exactly one server outbound." }
    val outbound = outbounds.getJSONObject(0)
    require(outbound.optString("protocol") == "vless") { "Unsupported VPN transport." }
    require(!outbound.has("proxySettings")) { "VLESS outbound chaining is not supported." }
    val stream = outbound.optJSONObject("streamSettings") ?: throw IllegalArgumentException("VLESS security configuration is missing.")
    val network = stream.optString("network", stream.optString("method", "tcp"))
    require(network in setOf("xhttp", "splithttp", "tcp", "raw")) { "Unsupported VLESS stream transport." }
    val security = stream.optString("security")
    require(security in setOf("tls", "reality")) { "VLESS requires authenticated transport security." }
    val tls = stream.optJSONObject(if (security == "tls") "tlsSettings" else "realitySettings")
      ?: throw IllegalArgumentException("VLESS transport security settings are missing.")
    require(!tls.optBoolean("allowInsecure", false)) { "Insecure VLESS TLS is not supported." }
    require(stream.optJSONObject("sockopt")?.has("dialerProxy") != true) { "VLESS socket detours are not supported." }
    // Copy only this outbound. Server inbounds, environment, DNS and routing
    // never gain authority to open listeners or create a direct escape path.
    return JSONObject(outbound.toString()).put("tag", OUTBOUND_TAG)
  }

  fun build(outbound: JSONObject, tunFd: Int, socksPort: Int, user: String, password: String): String {
    require(tunFd >= 0 && socksPort in 1..65535)
    val dns = JSONObject().put("servers", JSONArray().put("https://1.1.1.1/dns-query"))
      .put("tag", "vex-dns-query").put("queryStrategy", "UseIPv4").put("disableFallback", true)
    val dnsPolicy = JSONArray()
      // Upstream DNSOutboundRuleConfig uses PortList: a number or comma-separated string.
      .put(JSONObject().put("action", "hijack").put("qType", "1,28"))
      .put(JSONObject().put("action", "return").put("rCode", 5))
    val dnsOut = JSONObject().put("tag", "vex-dns").put("protocol", "dns")
      .put("settings", JSONObject().put("rules", dnsPolicy))
    val blocked = JSONObject().put("tag", "vex-block").put("protocol", "blackhole").put("settings", JSONObject())
    val tun = JSONObject().put("tag", "vex-tun").put("protocol", "tun")
      .put("settings", JSONObject().put("name", "vex-vless").put("MTU", MTU)
        .put("gateway", JSONArray().put("$TUN_ADDRESS/30").put("$TUN_IPV6/126")))
    val socks = JSONObject().put("tag", "vex-probe").put("listen", "127.0.0.1").put("port", socksPort).put("protocol", "socks")
      .put("settings", JSONObject().put("auth", "password").put("udp", false)
        .put("accounts", JSONArray().put(JSONObject().put("user", user).put("pass", password))))
    val rules = JSONArray()
      .put(JSONObject().put("type", "field").put("inboundTag", JSONArray().put("vex-dns-query")).put("outboundTag", OUTBOUND_TAG))
      .put(JSONObject().put("type", "field").put("inboundTag", JSONArray().put("vex-tun")).put("port", "53").put("outboundTag", "vex-dns"))
      // The VEX XHTTP fleet deliberately does not carry general UDP. DNS is
      // intercepted above and resolved over DoH through the VLESS outbound.
      .put(JSONObject().put("type", "field").put("network", "udp").put("outboundTag", "vex-block"))
    return JSONObject().put("log", JSONObject().put("loglevel", "none"))
      .put("env", JSONObject().put("xray.tun.fd", tunFd.toString()))
      .put("inbounds", JSONArray().put(tun).put(socks))
      .put("outbounds", JSONArray().put(JSONObject(outbound.toString())).put(dnsOut).put(blocked))
      .put("dns", dns).put("routing", JSONObject().put("domainStrategy", "AsIs").put("rules", rules)).toString()
  }
}
