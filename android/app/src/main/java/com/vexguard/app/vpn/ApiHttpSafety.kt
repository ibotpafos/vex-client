package com.vexguard.app.vpn

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Proxy
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream
import javax.net.SocketFactory
import okhttp3.Authenticator
import okhttp3.ConnectionPool
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink

internal data class ApiHttpReply(
  val status: Int,
  val statusText: String,
  val body: String,
  val headers: Map<String, String>,
)

// A terminal HTTP error is carried through OkHttp's failure callback so that
// its built-in 408/503 follow-up logic cannot hide the original status, even
// for GET/HEAD (whose requests cannot carry a one-shot body).
internal class ApiHttpError(val reply: ApiHttpReply) : IOException("API HTTP error")

/** Pure JVM HTTP safeguards shared by recovery and default-route mutations. */
internal object ApiHttpSafety {
  fun clientBuilder(base: OkHttpClient, pool: ConnectionPool, timeoutMs: Long,
                    ensureActive: () -> Unit,
                    onHttpErrorHeaders: (ApiHttpReply) -> Unit = {}): OkHttpClient.Builder {
    require(timeoutMs in 1L..120_000L)
    // newBuilder preserves SSLContext/trust manager, hostname verification and
    // certificate pinning. Do not inherit callbacks that can replay a request,
    // change its origin, supply ambient credentials or return a cached reply.
    return base.newBuilder().apply {
      interceptors().clear()
      networkInterceptors().clear()
    }
      .socketFactory(SocketFactory.getDefault())
      .dns(Dns.SYSTEM)
      .proxy(Proxy.NO_PROXY)
      .connectionPool(pool)
      .cache(null)
      .cookieJar(CookieJar.NO_COOKIES)
      .authenticator(Authenticator.NONE)
      .proxyAuthenticator(Authenticator.NONE)
      .retryOnConnectionFailure(false)
      .followRedirects(false)
      .followSslRedirects(false)
      .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
      .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
      .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
      .writeTimeout(timeoutMs, TimeUnit.MILLISECONDS)
      .addNetworkInterceptor { chain ->
        ensureActive()
        val response = chain.proceed(chain.request())
        if (response.code >= 400) {
          // Publish the denial before touching its body. A later call timeout
          // may replace our exception; it must not erase already received HTTP.
          onHttpErrorHeaders(headerReply(response))
          throw ApiHttpError(readReply(response, ensureActive))
        }
        response
      }
  }

  fun headerReply(response: Response): ApiHttpReply = ApiHttpReply(
    response.code, response.message, "",
    response.headers.toMultimap().mapValues { (_, values) -> values.joinToString(", ") },
  )

  fun requestBody(method: String, bytes: ByteArray?, contentType: MediaType?): RequestBody? {
    if (method == "GET" || method == "HEAD") {
      require(bytes == null)
      return null
    }
    // Empty DELETE/OPTIONS also need a body: without it, isOneShot cannot
    // prevent OkHttp's HTTP follow-ups. The write guard is defense in depth.
    val payload = bytes ?: ByteArray(0)
    return object : RequestBody() {
      private val written = AtomicBoolean(false)
      override fun contentType() = contentType
      override fun contentLength() = payload.size.toLong()
      override fun isOneShot() = true
      override fun writeTo(sink: BufferedSink) {
        if (!written.compareAndSet(false, true)) throw IOException("API body already sent")
        sink.write(payload)
      }
    }
  }

  fun readReply(response: Response, ensureActive: () -> Unit): ApiHttpReply {
    val status = response.code
    val statusText = response.message
    val headers = response.headers.toMultimap().mapValues { (_, values) -> values.joinToString(", ") }
    val body = try {
      response.use {
        ensureActive()
        val output = ByteArrayOutputStream()
        it.body?.byteStream()?.let { raw ->
          // Error interception runs below OkHttp's transparent gzip decoder.
          // Success replies reaching onResponse are already decoded and their
          // Content-Encoding header has been removed by OkHttp.
          if (it.header("Content-Encoding").equals("gzip", ignoreCase = true)) GZIPInputStream(raw) else raw
        }?.use { input ->
          val buffer = ByteArray(8192)
          while (true) {
            ensureActive()
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() + count > ApiRecoveryPolicy.MAX_BYTES) throw IOException("API response too large")
            output.write(buffer, 0, count)
          }
        }
        output.toString("UTF-8")
      }
    } catch (error: Exception) {
      // An unreadable error body must not turn a known HTTP failure into an
      // ambiguous transport failure eligible for JS failover. Cancellation and
      // the absolute deadline stop reading. The caller retains the earlier
      // header snapshot if cancellation prevents us from returning this reply.
      ensureActive()
      if (status < 400) throw error
      ""
    }
    ensureActive()
    return ApiHttpReply(status, statusText, body, headers)
  }
}
