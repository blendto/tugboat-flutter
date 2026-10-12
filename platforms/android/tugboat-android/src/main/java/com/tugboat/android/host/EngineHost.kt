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
 * Failures never reach the caller or crash the thread. A non-`ok` status is
 * logged, the message dropped, and its frame handles released;
 * [maxConsecutiveInternalErrors] `internal_error`s in a row shut the host
 * down for good.
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
    private val timers = TimerExecutor(handler) { timerId ->
        guarded("timer") { postNow(HostMessages.TIMER_FIRED, HostMessages.timerFiredInput(timerId)) }
    }
    private val effects = EffectDispatcher(timers, http, frames, ::postNow)

    /** Gates new posts; any thread reads it. */
    @Volatile
    private var accepting = true

    /** Engine thread only: false once shut down. */
    private var active = true
    private var consecutiveInternalErrors = 0

    /** False after [close] or after the host disabled itself. */
    val isRunning: Boolean
        get() = accepting

    /**
     * Submits one fact that happened at [at]. [frameHandles] are handles the
     * message passes to the engine; they are released if it is rejected.
     */
    fun post(type: String, inputJson: String, at: HostTime, frameHandles: List<String> = emptyList()) =
        enqueue(EngineMessage(type, inputJson, at, frameHandles))

    /** Submits [messages] as one all-or-nothing `batch`. */
    fun postBatch(messages: List<EngineMessage>) {
        if (messages.isEmpty()) return
        enqueue(EngineMessage.batchJson(messages), messages.flatMap { it.frameHandles })
    }

    /** Submits a message the engine takes without `at`: `engine.configure`, queries, stateless messages. */
    fun postUntimed(type: String, inputJson: String) = enqueue(EngineMessage(type, inputJson, at = null))

    /**
     * Submits `engine.dispose`, then cancels timers, closes IO, destroys the
     * handle, and frees frames, after already-posted work.
     */
    fun close() {
        accepting = false
        handler.post { guarded("shutdown") { shutDown() } }
    }

    private fun postNow(type: String, inputJson: String) = post(type, inputJson, clock.now())

    private fun enqueue(message: EngineMessage) = enqueue(message.toJson(), message.frameHandles)

    private fun enqueue(json: String, frameHandles: List<String>) {
        val queued = accepting && handler.post {
            if (active) process(json, frameHandles) else release(frameHandles)
        }
        if (!queued) release(frameHandles)
    }

    private fun process(json: String, frameHandles: List<String>) {
        val accepted = guarded("submit") { handle(transport.submit(json.toByteArray(Charsets.UTF_8))) } ?: false
        if (!accepted) release(frameHandles)
    }

    /** True when the engine accepted the message. */
    private fun handle(response: EngineResponse): Boolean {
        val status = response.status
        if (status == EngineStatus.INTERNAL_ERROR) {
            onInternalError(response)
            return false
        }
        consecutiveInternalErrors = 0
        if (status != EngineStatus.OK) {
            Log.w(TAG, "engine dropped a message (${status.wireName}): ${response.text()}")
            return false
        }
        val parsed = guarded("response") { EffectParser.parse(response.text()) }.orEmpty()
        parsed.forEach { effect -> guarded("effect ${effect.javaClass.simpleName}") { effects.dispatch(effect) } }
        return true
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

    private fun release(frameHandles: List<String>) = frameHandles.forEach(frames::release)

    private fun shutDown() {
        if (!active) return
        active = false
        guarded("dispose") { dispose() }
        guarded("timers") { timers.cancelAll() }
        guarded("http") { http.close() }
        guarded("transport") { transport.close() }
        frames.close()
        guarded("thread") { onShutDown() }
    }

    /**
     * Lets the engine report undelivered work before its handle goes. Its
     * effects run as usual except that no new IO or timer starts: `http.send`
     * and `timer.schedule` are dropped, `frame.release` is honoured. An engine
     * without `engine.dispose` (before phase 3b) answers `unsupported_message`,
     * which is logged and otherwise ignored.
     */
    private fun dispose() {
        val message = EngineMessage(HostMessages.ENGINE_DISPOSE, "{}", clock.now())
        val response = transport.submit(message.toJson().toByteArray(Charsets.UTF_8))
        if (response.status != EngineStatus.OK) {
            Log.w(TAG, "engine.dispose not accepted (${response.status.wireName}); destroying the handle")
            return
        }
        EffectParser.parse(response.text())
            .filterNot { it is Effect.HttpSend || it is Effect.TimerSchedule }
            .forEach { effect -> guarded("effect ${effect.javaClass.simpleName}") { effects.dispatch(effect) } }
    }

    /** Runs [block]; anything it throws is logged, never rethrown. */
    private inline fun <T> guarded(what: String, block: () -> T): T? =
        try {
            block()
        } catch (failure: Throwable) {
            Log.e(TAG, "engine host $what failed", failure)
            null
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
                http = HttpExecutor(config, frames::get),
                frames = frames,
                onShutDown = { thread.quitSafely() },
            )
        }
    }
}
