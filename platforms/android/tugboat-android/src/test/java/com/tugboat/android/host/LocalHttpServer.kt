package com.tugboat.android.host

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A one-connection-at-a-time HTTP/1.1 server on 127.0.0.1 for tests
 * (`com.sun.net.httpserver` is not on the Android unit-test classpath).
 * Header names are lowercased.
 */
internal class LocalHttpServer(
    /** Serves each connection on its own thread, so one slow reply does not hold the next request. */
    private val concurrent: Boolean = false,
) : AutoCloseable {
    class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

    class Response(val status: Int, val body: String = "", val headers: Map<String, String> = emptyMap())

    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val port: Int = socket.localPort
    val received = CopyOnWriteArrayList<Request>()

    @Volatile
    var reply: (Request) -> Response = { Response(202) }

    private val thread = Thread(::serve, "local-http-server").apply {
        isDaemon = true
        start()
    }

    override fun close() {
        socket.close()
        thread.join(5_000)
    }

    private fun serve() {
        while (true) {
            val client = try {
                socket.accept()
            } catch (closed: SocketException) {
                return
            }
            if (concurrent) {
                Thread({ serveQuietly(client) }, "local-http-exchange").apply { isDaemon = true }.start()
            } else {
                serveQuietly(client)
            }
        }
    }

    private fun serveQuietly(client: Socket) {
        try {
            client.use(::exchange)
        } catch (clientGone: IOException) {
            // The client timed out or hung up; serve the next one.
        }
    }

    private fun exchange(client: Socket) {
        val input = BufferedInputStream(client.getInputStream())
        val head = readHead(input) ?: return
        val lines = head.split("\r\n")
        val (method, path) = lines.first().split(" ")
        val headers = lines.drop(1).filter { it.isNotEmpty() }.associate { line ->
            line.substringBefore(':').trim().lowercase() to line.substringAfter(':').trim()
        }
        val length = headers["content-length"]?.toInt() ?: 0
        val request = Request(method, path, headers, readExactly(input, length))
        received += request
        val response = reply(request)
        val body = response.body.toByteArray(Charsets.UTF_8)
        val extra = response.headers.entries.joinToString("") { "${it.key}: ${it.value}\r\n" }
        val out = client.getOutputStream()
        out.write(
            ("HTTP/1.1 ${response.status} X\r\nContent-Length: ${body.size}\r\n$extra" +
                "Connection: close\r\n\r\n").toByteArray(Charsets.ISO_8859_1),
        )
        out.write(body)
        out.flush()
    }

    private fun readHead(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        var matched = 0
        while (matched < 4) {
            val byte = input.read()
            if (byte < 0) return null
            head.write(byte)
            matched = if (byte == "\r\n\r\n"[matched].code) matched + 1 else if (byte == '\r'.code) 1 else 0
        }
        return head.toString(Charsets.ISO_8859_1.name())
    }

    private fun readExactly(input: InputStream, length: Int): ByteArray {
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) break
            read += n
        }
        return body
    }
}
