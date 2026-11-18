package com.vexguard.app.vpn

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPOutputStream
import kotlin.concurrent.thread
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.Protocol
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

/** JVM-only HTTP/1 fixture: loopback sockets, no Android or external network. */
class ApiHttpSafetyTest {
  private data class Received(val method: String, val headers: Map<String, String>, val body: ByteArray)

  private class Fixture(private val reply: String, private val holdOpenMs: Long = 0) : Closeable {
    private val server = ServerSocket(0, 8, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
    val url = "http://127.0.0.1:${server.localPort}/v1/fixture"
    val requests = CopyOnWriteArrayList<Received>()
    private val failure = AtomicReference<Throwable?>()
    private val worker = thread(isDaemon = true, name = "api-http-loopback") {
      try {
        server.soTimeout = 300
        while (!server.isClosed) {
          val socket = try { server.accept() } catch (_: SocketTimeoutException) { break }
          socket.use {
            it.soTimeout = 1500
            val input = it.getInputStream()
            fun line(): String {
              val bytes = ByteArrayOutputStream()
              while (true) {
                val value = input.read()
                if (value < 0) throw IOException("Incomplete fixture request")
                if (value == 10) return bytes.toString("US-ASCII").trimEnd('\r')
                bytes.write(value)
              }
            }
            val method = line().substringBefore(' ')
            val headers = linkedMapOf<String, String>()
            while (true) {
              val header = line()
              if (header.isEmpty()) break
              headers[header.substringBefore(':').lowercase()] = header.substringAfter(':').trim()
            }
            val length = headers["content-length"]?.toInt() ?: 0
            val body = input.readNBytes(length)
            check(body.size == length)
            requests.add(Received(method, headers, body))
            it.getOutputStream().write(reply.toByteArray(Charsets.US_ASCII))
            it.getOutputStream().flush()
            if (holdOpenMs > 0) Thread.sleep(holdOpenMs)
          }
        }
      } catch (error: Throwable) {
        if (!server.isClosed) failure.set(error)
      }
    }
    fun assertCount(expected: Int) {
      worker.join(2000)
      assertFalse("Fixture worker did not finish", worker.isAlive)
      failure.get()?.let { throw AssertionError("Loopback fixture failed", it) }
      assertEquals(expected, requests.size)
    }
    override fun close() { server.close(); worker.join(2000) }
  }

  private fun response(status: Int, body: String = "", length: Int = body.length): String =
    "HTTP/1.1 $status Fixture\r\nRetry-After: 0\r\nX-Fixture: retained\r\nContent-Length: $length\r\nConnection: close\r\n\r\n$body"

  private fun client(base: OkHttpClient = OkHttpClient(), active: () -> Unit = {}): OkHttpClient =
    ApiHttpSafety.clientBuilder(base, ConnectionPool(0, 1, TimeUnit.SECONDS), 1500, active).build()

  private fun stop(client: OkHttpClient) {
    client.connectionPool.evictAll()
    client.dispatcher.executorService.shutdownNow()
  }

  private fun execute(client: OkHttpClient, request: Request, active: () -> Unit = {}): ApiHttpReply =
    try { ApiHttpSafety.readReply(client.newCall(request).execute(), active) }
    catch (error: ApiHttpError) { active(); error.reply }

  @Test fun mutationsAreSentOnceFor408And503IncludingEmptyBodies() {
    for (status in listOf(408, 503)) {
      for (method in listOf("POST", "PUT", "PATCH", "DELETE", "OPTIONS")) {
        for (payload in listOf<ByteArray?>(null, "fixture".toByteArray())) {
          Fixture(response(status)).use { fixture ->
            val client = client()
            try {
              val body = ApiHttpSafety.requestBody(method, payload, null)!!
              assertTrue(body.isOneShot())
              val request = Request.Builder().url(fixture.url).method(method, body).build()
              val reply = execute(client, request)
              assertEquals(status, reply.status)
              assertEquals("0", reply.headers["retry-after"])
              fixture.assertCount(1)
              assertEquals(method, fixture.requests.single().method)
              assertArrayEquals(payload ?: ByteArray(0), fixture.requests.single().body)
            } finally { stop(client) }
          }
        }
      }
    }
  }

  @Test fun oneShotBodyAloneStops503FollowUpWhereRetryFlagDoesNot() {
    // The control proves the fixture detects OkHttp's otherwise hidden resend.
    for (oneShot in listOf(false, true)) {
      Fixture(response(503)).use { fixture ->
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
        try {
          val body = if (oneShot) ApiHttpSafety.requestBody("POST", null, null)!! else ByteArray(0).toRequestBody()
          client.newCall(Request.Builder().url(fixture.url).post(body).build()).execute().close()
          fixture.assertCount(if (oneShot) 1 else 2)
        } finally { stop(client) }
      }
    }
  }

  @Test fun getHttpErrorRemainsTerminalAndRetainsHeadersWhenBodyIsTruncated() {
    for (status in listOf(401, 408, 429, 503)) {
      Fixture(response(status, "partial", 100)).use { fixture ->
        val client = client()
        try {
          val reply = execute(client, Request.Builder().url(fixture.url).get().build())
          assertEquals(status, reply.status)
          assertEquals("Fixture", reply.statusText)
          assertEquals("0", reply.headers["retry-after"])
          assertEquals("retained", reply.headers["x-fixture"])
          assertEquals("", reply.body)
          fixture.assertCount(1)
        } finally { stop(client) }
      }
    }
  }

  @Test fun completeHttpErrorBodyIsPreserved() {
    Fixture(response(409, "conflict")).use { fixture ->
      val client = client()
      try {
        val request = Request.Builder().url(fixture.url).post(ApiHttpSafety.requestBody("POST", null, null)!!).build()
        assertEquals("conflict", execute(client, request).body)
        fixture.assertCount(1)
      } finally { stop(client) }
    }
  }

  @Test fun receivedHttpHeadersSurviveBodyTimeoutAndCancellation() {
    for (cancel in listOf(false, true)) {
      Fixture(response(401, "partial", 100), holdOpenMs = 500).use { fixture ->
        val knownHttp = AtomicReference<ApiHttpReply?>()
        val received = CountDownLatch(1)
        val client = ApiHttpSafety.clientBuilder(OkHttpClient(), ConnectionPool(0, 1, TimeUnit.SECONDS), 150,
          ensureActive = {}, onHttpErrorHeaders = { knownHttp.set(it); received.countDown() }).build()
        val call = client.newCall(Request.Builder().url(fixture.url).build())
        val canceller = if (cancel) thread(isDaemon = true) {
          check(received.await(1, TimeUnit.SECONDS))
          call.cancel()
        } else null
        try {
          val reply = try {
            ApiHttpSafety.readReply(call.execute()) {}
          } catch (error: IOException) {
            // Same precedence as the native onFailure callback: an actual HTTP
            // snapshot survives even a replacement timeout/cancel exception.
            if (error is ApiHttpError) error.reply else knownHttp.get() ?: throw error
          }
          assertEquals(401, reply.status)
          assertEquals("0", reply.headers["retry-after"])
          assertEquals("retained", reply.headers["x-fixture"])
          assertEquals("", reply.body)
          fixture.assertCount(1)
        } finally { canceller?.join(1000); stop(client) }
      }
    }
  }

  @Test fun headersArePublishedBeforeOversizedErrorBodyIsDiscarded() {
    val knownHttp = AtomicReference<ApiHttpReply?>()
    Fixture(response(429, "x".repeat(ApiRecoveryPolicy.MAX_BYTES + 1))).use { fixture ->
      val client = ApiHttpSafety.clientBuilder(OkHttpClient(), ConnectionPool(0, 1, TimeUnit.SECONDS), 1500,
        ensureActive = {}, onHttpErrorHeaders = { knownHttp.set(it) }).build()
      try {
        val reply = execute(client, Request.Builder().url(fixture.url).build())
        assertEquals(429, reply.status)
        assertEquals("", reply.body)
        assertEquals(429, knownHttp.get()!!.status)
        assertEquals("0", knownHttp.get()!!.headers["retry-after"])
        fixture.assertCount(1)
      } finally { stop(client) }
    }
  }

  @Test fun successBodyReadFailureRemainsTransportFailure() {
    Fixture(response(200, "partial", 100)).use { fixture ->
      val client = client()
      try {
        try {
          execute(client, Request.Builder().url(fixture.url).build())
          fail("Truncated success must not resolve")
        } catch (_: IOException) { }
        fixture.assertCount(1)
      } finally { stop(client) }
    }
  }

  @Test fun cancellationAndDeadlineOverrideKnownHttpError() {
    for (reason in listOf("cancelled", "deadline")) {
      val response = Response.Builder().request(Request.Builder().url("https://api.vexguard.app/v1/fixture").build())
        .protocol(Protocol.HTTP_1_1).code(503).message("Fixture").body("error".toResponseBody()).build()
      try {
        ApiHttpSafety.readReply(response) { throw IOException(reason) }
        fail("Inactive request must not resolve its HTTP error")
      } catch (error: IOException) { assertEquals(reason, error.message) }
    }
  }

  @Test fun responseLimitAndSingleWriteGuardAreEnforced() {
    for (status in listOf(200, 503)) {
      val response = Response.Builder().request(Request.Builder().url("https://api.vexguard.app/v1/fixture").build())
        .protocol(Protocol.HTTP_1_1).code(status).message("Fixture")
        .body(ByteArray(ApiRecoveryPolicy.MAX_BYTES + 1).toResponseBody()).build()
      try {
        val reply = ApiHttpSafety.readReply(response) {}
        assertEquals(503, status)
        assertEquals("", reply.body)
      } catch (_: IOException) { assertEquals(200, status) }
    }
    val body = ApiHttpSafety.requestBody("DELETE", null, null)!!
    body.writeTo(Buffer())
    try { body.writeTo(Buffer()); fail("Body must not write twice") } catch (_: IOException) { }
    assertNull(ApiHttpSafety.requestBody("GET", null, null))
    assertNull(ApiHttpSafety.requestBody("HEAD", null, null))
  }

  @Test fun compressedErrorBodyIsDecodedBeforeReturningToJs() {
    val output = ByteArrayOutputStream()
    GZIPOutputStream(output).use { it.write("conflict".toByteArray()) }
    val response = Response.Builder().request(Request.Builder().url("https://api.vexguard.app/v1/fixture").build())
      .protocol(Protocol.HTTP_1_1).code(409).message("Fixture").header("Content-Encoding", "gzip")
      .body(output.toByteArray().toResponseBody()).build()
    assertEquals("conflict", ApiHttpSafety.readReply(response) {}.body)
  }

  @Test fun inheritedReplayHooksAreRemovedAndTlsIsPreserved() {
    val base = OkHttpClient.Builder()
      .authenticator { _, _ -> throw AssertionError("Inherited authentication ran") }
      .proxyAuthenticator { _, _ -> throw AssertionError("Inherited proxy authentication ran") }
      .addInterceptor { throw AssertionError("Inherited interceptor ran") }
      .addNetworkInterceptor { throw AssertionError("Inherited network interceptor ran") }
      .build()
    val client = client(base)
    try {
      assertTrue(client.interceptors.isEmpty())
      assertEquals(1, client.networkInterceptors.size)
      assertSame(Authenticator.NONE, client.authenticator)
      assertSame(Authenticator.NONE, client.proxyAuthenticator)
      assertSame(CookieJar.NO_COOKIES, client.cookieJar)
      assertNull(client.cache)
      assertFalse(client.retryOnConnectionFailure)
      assertFalse(client.followRedirects)
      assertFalse(client.followSslRedirects)
      assertSame(base.sslSocketFactory, client.sslSocketFactory)
      assertSame(base.hostnameVerifier, client.hostnameVerifier)
      assertEquals(base.certificatePinner, client.certificatePinner)
      assertSame(javax.net.SocketFactory.getDefault(), client.socketFactory)
      assertSame(okhttp3.Dns.SYSTEM, client.dns)
      Fixture(response(401)).use { fixture ->
        assertEquals(401, execute(client, Request.Builder().url(fixture.url).build()).status)
        fixture.assertCount(1)
      }
    } finally { stop(client) }
  }
}
