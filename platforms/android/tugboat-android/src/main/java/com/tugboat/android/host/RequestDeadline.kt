package com.tugboat.android.host

import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * A total deadline for one request. `HttpURLConnection` has no write timeout
 * and its read timeout restarts with every chunk, so a stalled upload or a
 * dribbling response could otherwise outlive `timeoutMs` indefinitely.
 *
 * At the deadline this disconnects the attached connection, which fails a
 * blocked write or read. Some implementations (the JDK's keep-alive body
 * stream) drain instead of closing on disconnect, so readers also call
 * [check] between reads. The executor reports `timeout` whenever [expired]
 * is set.
 */
internal class RequestDeadline(scheduler: ScheduledExecutorService, timeoutMs: Long) {
    @Volatile
    var expired = false
        private set

    @Volatile
    private var connection: HttpURLConnection? = null

    private val task = scheduler.schedule(::expire, timeoutMs, TimeUnit.MILLISECONDS)

    /** Attaches the connection to disconnect at the deadline (at once if it already passed). */
    fun attach(connection: HttpURLConnection) {
        this.connection = connection
        if (expired) disconnectQuietly(connection)
    }

    /** Throws [SocketTimeoutException] once the deadline has passed. */
    fun check() {
        if (expired) throw SocketTimeoutException("request deadline passed")
    }

    /** Disarms the deadline once the request has finished. */
    fun cancel() {
        task.cancel(false)
    }

    private fun expire() {
        expired = true
        connection?.let(::disconnectQuietly)
    }

    private fun disconnectQuietly(connection: HttpURLConnection) {
        try {
            connection.disconnect()
        } catch (ignored: Throwable) {
            // The request thread reports the outcome; nothing to add here.
        }
    }
}
