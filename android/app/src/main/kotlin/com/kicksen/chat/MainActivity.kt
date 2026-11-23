package com.kicksen.chat

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kicksen/oauth_proxy")
            .setMethodCallHandler { call, result ->
                if (call.method != "request") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val method = call.argument<String>("method")
                val url = call.argument<String>("url")
                val headers = call.argument<Map<String, String>>("headers")
                val body = call.argument<ByteArray>("body")
                if (method == null || url == null) {
                    result.error("INVALID_REQUEST", "Missing method or URL", null)
                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        val response = request(method, url, headers.orEmpty(), body ?: ByteArray(0))
                        Handler(Looper.getMainLooper()).post { result.success(response) }
                    } catch (error: Exception) {
                        Handler(Looper.getMainLooper()).post {
                            result.error("NETWORK_ERROR", error.message, null)
                        }
                    }
                }.start()
            }
    }

    private fun request(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray,
    ): Map<String, Any> {
        val target = URL(url)
        val connection = target.openConnection() as HttpsURLConnection
        if (target.host.endsWith(".workers.dev")) {
            connection.sslSocketFactory = WorkerSslSocketFactory(
                target.host,
                if (target.port >= 0) target.port else 443,
            )
        }

        return try {
            val requestMethod = method.uppercase(Locale.ROOT)
            val hasBody = requestMethod in setOf("POST", "PUT", "PATCH")
            connection.requestMethod = requestMethod
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            if (hasBody) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }

            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val responseBody = stream?.use { it.readBytes() } ?: ByteArray(0)
            val responseHeaders = connection.headerFields
                .filterKeys { it != null }
                .mapValues { (_, value) -> value.joinToString(",") }
            mapOf(
                "status" to status,
                "headers" to responseHeaders,
                "body" to responseBody,
            )
        } finally {
            connection.disconnect()
        }
    }
}

private object WorkerDns {
    private val cache = ConcurrentHashMap<String, String>()

    fun resolve(host: String): String {
        cache[host]?.let { return it }
        try {
            InetAddress.getAllByName(host)
                .filterIsInstance<Inet4Address>()
                .firstOrNull()
                ?.let {
                    cache[host] = it.hostAddress
                    return it.hostAddress
                }
        } catch (_: Exception) {
        }

        var lastError: Exception? = null
        val endpoints = listOf(
            "https://1.1.1.1/dns-query",
            "https://8.8.8.8/resolve",
        )
        for (endpoint in endpoints) {
            var connection: HttpsURLConnection? = null
            try {
                connection = URL("$endpoint?name=$host&type=A").openConnection() as HttpsURLConnection
                connection.connectTimeout = 10000
                connection.readTimeout = 10000
                connection.setRequestProperty("Accept", "application/dns-json")
                val text = connection.inputStream.bufferedReader().use { it.readText() }
                val answers = JSONObject(text).optJSONArray("Answer")
                for (index in 0 until (answers?.length() ?: 0)) {
                    val answer = answers!!.getJSONObject(index)
                    if (answer.optInt("type") == 1) {
                        val address = answer.getString("data")
                        cache[host] = address
                        return address
                    }
                }
                throw SocketException("No IPv4 address returned for $host")
            } catch (error: Exception) {
                lastError = error
            } finally {
                connection?.disconnect()
            }
        }
        throw SocketException("Failed to resolve $host: ${lastError?.message}")
    }
}

private class WorkerSocket(host: String, port: Int) : Socket() {
    init {
        super.connect(InetSocketAddress(WorkerDns.resolve(host), port), 15000)
    }

    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        if (!isConnected) super.connect(endpoint, timeout)
    }
}

private class WorkerSslSocketFactory(
    private val expectedHost: String,
    private val expectedPort: Int,
) : SSLSocketFactory() {
    private val delegate = getDefault() as SSLSocketFactory

    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(): Socket = WorkerSocket(expectedHost, expectedPort)

    override fun createSocket(host: String, port: Int): Socket = connect(host, port, null, 0)

    override fun createSocket(
        host: String,
        port: Int,
        localHost: InetAddress,
        localPort: Int,
    ): Socket = connect(host, port, localHost, localPort)

    override fun createSocket(host: InetAddress, port: Int): Socket =
        connect(expectedHost, port, null, 0)

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = connect(expectedHost, port, localAddress, localPort)

    override fun createSocket(
        socket: Socket,
        host: String,
        port: Int,
        autoClose: Boolean,
    ): Socket = delegate.createSocket(socket, host, port, autoClose)

    private fun connect(
        host: String,
        port: Int,
        localAddress: InetAddress?,
        localPort: Int,
    ): Socket {
        val socket = Socket()
        if (localAddress != null) socket.bind(InetSocketAddress(localAddress, localPort))
        socket.connect(InetSocketAddress(WorkerDns.resolve(host), port), 15000)
        return delegate.createSocket(socket, host, port, true)
    }
}
