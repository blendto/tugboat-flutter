package com.tugboat.android.host

import android.util.Log
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Runs `http.send` effects with `HttpURLConnection` on one IO thread (the
 * engine keeps at most one request in flight). Headers and bodies match the
 * Flutter `CollectorHttpSink`. Every failure becomes a [TransportOutcome];
 * nothing is thrown to the caller.
 */
internal class HttpExecutor(
    private val config: HostConfig,
    private val frames: FrameHandleTable,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "tugboat-io").apply { isDaemon = true }
    },
) : HttpSender {
    override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
        try {
            executor.execute { onResult(perform(request)) }
        } catch (closed: RejectedExecutionException) {
            onResult(TransportOutcome.Error)
        }
    }

    override fun close() {
        executor.shutdownNow()
    }

    /** Performs [request] on the calling thread. */
    fun perform(request: HttpRequest): TransportOutcome {
        val payload = payload(request.body) ?: return TransportOutcome.Error
        var connection: HttpURLConnection? = null
        return try {
            connection = open(request)
            connection.setRequestProperty("Content-Type", payload.contentType)
            connection.setFixedLengthStreamingMode(payload.bytes.size)
            connection.outputStream.use { it.write(payload.bytes) }
            val status = connection.responseCode
            TransportOutcome.Http(status, readBody(connection, status))
        } catch (timeout: SocketTimeoutException) {
            TransportOutcome.Timeout
        } catch (error: Exception) {
            // IOException, a malformed base URL, or a missing INTERNET permission.
            Log.w(TAG, "${request.lane} ${request.path} failed: ${error.javaClass.simpleName}")
            TransportOutcome.Error
        } finally {
            connection?.disconnect()
        }
    }

    private fun open(request: HttpRequest): HttpURLConnection {
        // Same resolution as Dart's `Uri.resolve` on the trimmed base URL.
        val url = URI(config.collectorBaseUrl.trimEnd('/')).resolve(request.path).toURL()
        val timeoutMs = request.timeoutMs.coerceAtLeast(1)
        return (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            useCaches = false
            // dart:io does not follow redirects for POST; report the 3xx instead.
            instanceFollowRedirects = false
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            for ((name, value) in config.collectorHeaders()) setRequestProperty(name, value)
        }
    }

    private fun payload(body: HttpBody): Payload? =
        when (body) {
            is HttpBody.Json -> Payload(JSON_CONTENT_TYPE, body.text.toByteArray(Charsets.UTF_8))
            is HttpBody.Multipart -> multipartPayload(body)
        }

    private fun multipartPayload(body: HttpBody.Multipart): Payload? {
        val files = body.frames.map { frame ->
            val jpeg = frames[frame.handle]
            if (jpeg == null) {
                Log.w(TAG, "frame handle ${frame.handle} is not in the table")
                return null
            }
            MultipartBody.File(FRAMES_FIELD, frame.filename, JPEG_CONTENT_TYPE, jpeg)
        }
        val multipart = MultipartBody(body.fields, files)
        return Payload(multipart.contentType, multipart.toByteArray())
    }

    private fun readBody(connection: HttpURLConnection, status: Int): String {
        val stream = (if (status >= 400) connection.errorStream else connection.inputStream) ?: return ""
        return stream.use(::readPrefix).toString(Charsets.UTF_8)
    }

    private class Payload(val contentType: String, val bytes: ByteArray)

    companion object {
        /** `transport.result.body` carries at most this many bytes of the response. */
        const val MAX_BODY_BYTES = 64 * 1024

        private const val TAG = "TugboatHttp"

        /** Dart's `http` adds the charset to the sink's `application/json`. */
        private const val JSON_CONTENT_TYPE = "application/json; charset=utf-8"
        private const val JPEG_CONTENT_TYPE = "image/jpeg"
        private const val FRAMES_FIELD = "files"

        private fun readPrefix(stream: InputStream): ByteArray {
            val buffer = ByteArray(MAX_BODY_BYTES)
            var length = 0
            while (length < buffer.size) {
                val read = stream.read(buffer, length, buffer.size - length)
                if (read < 0) break
                length += read
            }
            return buffer.copyOf(length)
        }
    }
}
