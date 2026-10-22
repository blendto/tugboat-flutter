package com.tugboat.android.host

import android.util.Log
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledThreadPoolExecutor

/**
 * Runs `http.send` effects with `HttpURLConnection` on one IO thread (the
 * engine keeps at most one request in flight). Headers and bodies match the
 * Flutter `CollectorHttpSink`. `timeoutMs` is a total deadline
 * ([RequestDeadline]). Every failure, including an `Error`, becomes a
 * [TransportOutcome]; nothing is thrown to the caller. Every outcome is one
 * the engine accepts ([CollectorResponse]).
 */
internal class HttpExecutor(
    private val config: HostConfig,
    /** JPEG bytes for a frame handle at send time; normally [FrameHandleTable.get]. */
    private val frameBytes: (handle: String) -> ByteArray?,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task -> daemon(task, "tugboat-io") },
    private val watchdog: ScheduledExecutorService = ScheduledThreadPoolExecutor(1) { task ->
        daemon(task, "tugboat-io-deadline")
    }.apply { removeOnCancelPolicy = true },
) : HttpSender {
    override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
        val send = Send(request, onResult)
        try {
            executor.execute(send)
        } catch (closedOrFailed: Throwable) {
            send.abandon()
        }
    }

    /**
     * Requests that never started are answered with [TransportOutcome.Error].
     * A request already running keeps its deadline and answers normally.
     */
    override fun close() {
        executor.shutdownNow().forEach { (it as? Send)?.abandon() }
        watchdog.shutdown()
    }

    /** Performs [request] on the calling thread. Never throws. */
    fun perform(request: HttpRequest): TransportOutcome {
        var deadline: RequestDeadline? = null
        var connection: HttpURLConnection? = null
        return try {
            val payload = payload(request.body) ?: return TransportOutcome.Error
            deadline = RequestDeadline(watchdog, request.timeoutMs.coerceAtLeast(1).toLong())
            connection = open(request).also(deadline::attach)
            connection.setRequestProperty("Content-Type", payload.contentType)
            connection.setFixedLengthStreamingMode(payload.bytes.size)
            connection.outputStream.use { it.write(payload.bytes) }
            val status = connection.responseCode
            val body = readBody(connection, status, deadline)
            deadline.check()
            val retryAfter = CollectorResponse.forwardRetryAfter(
                connection.getHeaderField("Retry-After"),
            )
            CollectorResponse.outcome(status, body, retryAfter)
        } catch (failure: Throwable) {
            if (deadline?.expired == true || failure is SocketTimeoutException) {
                TransportOutcome.Timeout
            } else {
                // IO failure, malformed base URL, missing INTERNET permission, OOM.
                Log.w(TAG, "${request.lane} ${request.path} failed: ${failure.javaClass.simpleName}")
                TransportOutcome.Error
            }
        } finally {
            deadline?.cancel()
            // Past the deadline the watchdog has already disconnected (see readBody).
            if (deadline?.expired != true) disconnectQuietly(connection)
        }
    }

    private fun disconnectQuietly(connection: HttpURLConnection?) {
        try {
            connection?.disconnect()
        } catch (ignored: Throwable) {
            // The outcome is already decided.
        }
    }

    /** One queued request; answers exactly once, whether it runs or is abandoned. */
    private inner class Send(
        private val request: HttpRequest,
        private val onResult: (TransportOutcome) -> Unit,
    ) : Runnable {
        override fun run() = deliver(perform(request))

        fun abandon() = deliver(TransportOutcome.Error)

        private fun deliver(outcome: TransportOutcome) {
            try {
                onResult(outcome)
            } catch (failure: Throwable) {
                Log.e(TAG, "transport result callback failed", failure)
            }
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
            // Per-operation bounds; the total bound is the RequestDeadline.
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
            val jpeg = frameBytes(frame.handle)
            if (jpeg == null) {
                Log.w(TAG, "frame handle ${frame.handle} is not in the table")
                return null
            }
            MultipartBody.File(FRAMES_FIELD, frame.filename, JPEG_CONTENT_TYPE, jpeg)
        }
        val multipart = MultipartBody(body.fields, files)
        return Payload(multipart.contentType, multipart.toByteArray())
    }

    /**
     * Reads at most [CollectorResponse.MAX_BODY_BYTES] bytes. The stream is closed only on success: a
     * failed read leaves it to `disconnect()`, and closing a JDK keep-alive
     * stream that the deadline's disconnect handed to its drain thread blocks
     * until the drain ends.
     */
    private fun readBody(connection: HttpURLConnection, status: Int, deadline: RequestDeadline): ByteArray {
        val stream = (if (status >= 400) connection.errorStream else connection.inputStream) ?: return ByteArray(0)
        val body = readPrefix(stream, deadline)
        stream.close()
        return body
    }

    private class Payload(val contentType: String, val bytes: ByteArray)

    companion object {
        private const val TAG = "TugboatHttp"

        /** Dart's `http` adds the charset to the sink's `application/json`. */
        private const val JSON_CONTENT_TYPE = "application/json; charset=utf-8"
        private const val JPEG_CONTENT_TYPE = "image/jpeg"
        private const val FRAMES_FIELD = "files"

        private fun daemon(task: Runnable, name: String) = Thread(task, name).apply { isDaemon = true }

        private fun readPrefix(stream: InputStream, deadline: RequestDeadline): ByteArray {
            val buffer = ByteArray(CollectorResponse.MAX_BODY_BYTES)
            var length = 0
            while (length < buffer.size) {
                deadline.check()
                val read = stream.read(buffer, length, buffer.size - length)
                if (read < 0) break
                length += read
            }
            return buffer.copyOf(length)
        }
    }
}
