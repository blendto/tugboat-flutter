package com.tugboat.android.host

import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import com.tugboat.android.engine.EngineResponse
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.engine.EngineTransport

/**
 * Owns one engine handle ([transport]) and drives it from one thread, the
 * looper behind [handler]. `post*` may be called from any thread; every
 * submit, response, and effect runs on that looper, in post order.
 *
 * Failures never reach the caller. A non-`ok` status is logged and the
 * message dropped; [maxConsecutiveInternalErrors] `internal_error`s in a row
 * shut the host down for good.
 */
internal class EngineHost(
    private val transport: EngineTransport,
    private val handler: Handler,
    private val http: HttpSender,
    private val frames: FrameHandleTable,
    private val clock: HostClock = SystemHostClock,
    private val maxConsecutiveInternalErrors: Int = DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS,
    private val onShutDown: () -> Unit = {},
) {
    private val timers = TimerExecutor(handler) { timerId -> post(HostMessages.timerFired(timerId)) }
    private val effects = EffectDispatcher(timers, http, frames, ::post)

    /** Gates new posts; any thread reads it. */
    @Volatile
    private var accepting = true

    /** Engine thread only: false once shut down. */
    private var active = true
    private var consecutiveInternalErrors = 0

    /** False after [close] or after the host disabled itself. */
    val isRunning: Boolean
        get() = accepting

    /** Submits [message], stamped with `at` = now unless it carries its own. */
    fun post(message: String) {
        val at = clock.now()
        enqueue { HostMessages.stamped(message, at) }
    }

    /** Submits [messages] as one `batch`; each is stamped like [post]. */
    fun postBatch(messages: List<String>) {
        if (messages.isEmpty()) return
        val at = clock.now()
        enqueue { HostMessages.batch(messages.map { HostMessages.stamped(it, at) }) }
    }

    /**
     * Submits [message] without adding `at`, for the messages the engine
     * rejects it on: `engine.configure`, queries, and stateless messages.
     */
    fun postUntimed(message: String) = enqueue { message }

    /** Cancels timers, closes IO, destroys the handle, and frees frames, after already-posted work. */
    fun close() {
        accepting = false
        handler.post(::shutDown)
    }

    private fun enqueue(message: () -> String) {
        if (!accepting) return
        handler.post {
            if (active) process(message)
        }
    }

    private fun process(message: () -> String) {
        try {
            handle(transport.submit(message().toByteArray(Charsets.UTF_8)))
        } catch (error: Exception) {
            Log.e(TAG, "engine host failure", error)
        }
    }

    private fun handle(response: EngineResponse) {
        val status = response.status
        if (status == EngineStatus.INTERNAL_ERROR) {
            onInternalError(response)
            return
        }
        consecutiveInternalErrors = 0
        if (status != EngineStatus.OK) {
            Log.w(TAG, "engine dropped a message (${status.wireName}): ${response.text()}")
            return
        }
        for (effect in EffectParser.parse(response.text())) {
            try {
                effects.dispatch(effect)
            } catch (error: Exception) {
                Log.e(TAG, "effect failed: $effect", error)
            }
        }
    }

    private fun onInternalError(response: EngineResponse) {
        consecutiveInternalErrors++
        Log.e(TAG, "engine internal_error ($consecutiveInternalErrors in a row): ${response.text()}")
        if (consecutiveInternalErrors >= maxConsecutiveInternalErrors) {
            Log.e(TAG, "disabling the Tugboat engine host for this process")
            accepting = false
            shutDown()
        }
    }

    private fun shutDown() {
        if (!active) return
        active = false
        timers.cancelAll()
        http.close()
        transport.close()
        frames.clear()
        onShutDown()
    }

    companion object {
        const val DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS = 3
        private const val TAG = "TugboatEngine"

        /** Starts a host on a new `tugboat-engine` thread; the host owns [transport]. */
        fun start(config: HostConfig, transport: EngineTransport, frames: FrameHandleTable): EngineHost {
            val thread = HandlerThread("tugboat-engine", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
            return EngineHost(
                transport = transport,
                handler = Handler(thread.looper),
                http = HttpExecutor(config, frames),
                frames = frames,
                onShutDown = { thread.quitSafely() },
            )
        }
    }
}
