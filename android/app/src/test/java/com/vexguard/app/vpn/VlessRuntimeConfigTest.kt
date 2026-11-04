package com.vexguard.app.vpn

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VlessRuntimeConfigTest {
  private fun outbound() = JSONObject("""{
    "protocol":"vless","tag":"server-template",
    "settings":{"vnext":[{"address":"fixture.example","port":443,"users":[{"id":"synthetic-fixture-id","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"fixture.example","alpn":["h2"]},
    "xhttpSettings":{"path":"/synthetic-path","mode":"stream-one","extra":{"xmux":{"maxConcurrency":8}}}}
  }""")
  private fun source(server: JSONObject = outbound()) = JSONObject().put("outbounds", JSONArray().put(server))
  private fun reject(value: String, routing: String = "{\"mode\":\"full_tunnel\"}") {
    try {
      VlessRuntimeConfig.admit(value, routing)
      fail("Unsupported input was admitted")
    } catch (failure: IllegalArgumentException) {
      assertEquals("VLESS configuration or routing policy is unsupported.", failure.message)
      assertNull(failure.cause)
    }
  }

  @Test fun xhttpTlsAndCredentialsRemainSemanticallyUnmodified() {
    val original = outbound()
    val admitted = VlessRuntimeConfig.admit(source(original).toString(), "{\"mode\":\"full_tunnel\"}")
    assertTrue(original.getJSONObject("settings").similar(admitted.getJSONObject("settings")))
    assertTrue(original.getJSONObject("streamSettings").similar(admitted.getJSONObject("streamSettings")))
  }

  @Test fun clientOwnsTunProtectedDnsAndEveryRouteWithoutFreedomFallback() {
    val admitted = VlessRuntimeConfig.admit(source().toString(), "")
    val config = JSONObject(VlessRuntimeConfig.build(admitted, 44, 12345, "fixture-user", "fixture-password"))
    assertEquals("44", config.getJSONObject("env").getString("xray.tun.fd"))
    assertEquals("UseIPv4", config.getJSONObject("dns").getString("queryStrategy"))
    assertTrue(config.getJSONObject("dns").getBoolean("disableFallback"))
    assertEquals("https://1.1.1.1/dns-query", config.getJSONObject("dns").getJSONArray("servers").getString(0))
    val outbounds = config.getJSONArray("outbounds")
    assertEquals(listOf("vless", "dns", "blackhole"), (0 until outbounds.length()).map { outbounds.getJSONObject(it).getString("protocol") })
    val dnsPolicy = outbounds.getJSONObject(1).getJSONObject("settings").getJSONArray("rules")
    assertEquals("hijack", dnsPolicy.getJSONObject(0).getString("action"))
    assertEquals("[1,28]", dnsPolicy.getJSONObject(0).getJSONArray("qType").toString())
    assertEquals("return", dnsPolicy.getJSONObject(1).getString("action"))
    assertEquals(5, dnsPolicy.getJSONObject(1).getInt("rCode"))
    val rules = config.getJSONObject("routing").getJSONArray("rules")
    assertEquals("vex-vless", rules.getJSONObject(0).getString("outboundTag"))
    assertEquals("vex-dns", rules.getJSONObject(1).getString("outboundTag"))
    assertEquals("udp", rules.getJSONObject(2).getString("network"))
    assertEquals("vex-block", rules.getJSONObject(2).getString("outboundTag"))
    val socks = config.getJSONArray("inbounds").getJSONObject(1)
    assertEquals("127.0.0.1", socks.getString("listen"))
    assertEquals("password", socks.getJSONObject("settings").getString("auth"))
    assertFalse(socks.getJSONObject("settings").getBoolean("udp"))
  }

  @Test fun serverListenersAndEnvironmentNeverGainAuthority() {
    val value = source().put("env", JSONObject().put("xray.tun.fd", "sensitive-value"))
      .put("inbounds", JSONArray().put(JSONObject().put("listen", "0.0.0.0")))
      .put("routing", JSONObject().put("domainStrategy", "IPOnDemand"))
    val admitted = VlessRuntimeConfig.admit(value.toString(), "")
    assertFalse(admitted.has("env"))
    assertFalse(admitted.has("inbounds"))
    assertFalse(admitted.has("routing"))
  }

  @Test fun unsafeTransportDirectDetoursAndUnsupportedRoutingAreRejectedBeforeActivation() {
    reject(source().put("outbounds", JSONArray().put(outbound()).put(JSONObject().put("protocol", "freedom"))).toString())
    reject(source(outbound().put("proxySettings", JSONObject().put("tag", "direct"))).toString())
    reject(source(outbound().apply { getJSONObject("streamSettings").put("security", "none") }).toString())
    reject(source(outbound().apply { getJSONObject("streamSettings").put("network", "httpupgrade") }).toString())
    reject(source(outbound().apply { getJSONObject("streamSettings").getJSONObject("tlsSettings").put("allowInsecure", true) }).toString())
    reject(source().toString(), "{\"mode\":\"all_except_ru\"}")
    reject("credential-bearing-invalid-json")
    reject("x".repeat(VlessRuntimeConfig.MAX_CONFIG_BYTES + 1))
  }
}
