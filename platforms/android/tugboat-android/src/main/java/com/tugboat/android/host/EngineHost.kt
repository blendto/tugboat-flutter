package com.tugboat.android.host

import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import com.tugboat.android.engine.EngineResponse
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.engine.EngineTransport
import org.json.JSONObject

/**
 * What the collector sink holds and has lost, with the fields of Dart's
 * `TugboatSinkHealth`: [pending] events and frames queued, waiting for a retry,
 * or in a request; [accepted] and [dropped] running totals over every session.
 */
internal data class SinkHealth(val pending: Long, val accepted: Long, val dropped: Long)

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
    /** Performs `capture.request`; it answers through [post] with `capture.result`. */
    captures: CaptureRequestSink,
    /** Runs the settled re-sample watch (`scene.watch`, `scene.sample`). */
    scenes: SceneWatchSink = SceneWatchSink.NONE,
) {
    private val timers = TimerExecutor(handler) { timerId ->
        guarded("timer") { postNow(HostMessages.TIMER_FIRED, HostMessages.timerFiredInput(timerId)) }
    }
    private val effects = EffectDispatcher(timers, http, frames, ::postNow, captures, scenes)

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
     * Like [postUntimed], but [inputJson] runs on the engine thread when the
     * message is reached, after everything posted before it. If [inputJson]
     * throws, the failure is logged and the host shuts down (no message goes
     * out, [isRunning] turns false). For an input
     * that needs blocking work (the installation id file): the caller does
     * not wait, and the messages queued behind it still go out in order.
     */
    fun postUntimedLazily(type: String, inputJson: () -> String) {
        accepting && handler.post {
            if (active) {
                val json = guarded("lazy input") { EngineMessage(type, inputJson(), at = null).toJson() }
                if (json != null) {
                    process(json, emptyList())
                } else {
                    // The message cannot be built, so the session could never start: stop for good, as on a
                    // fatal engine status, instead of reporting a running session the engine never had.
                    Log.e(TAG, "disabling the Tugboat engine host for this process: $type input failed")
                    accepting = false
                    shutDown()
                }
            }
        }
    }

    /**
     * Reads the collector sink's health from the engine, on the engine
     * thread, after already-posted work: [onResult] gets it there, or null
     * when the host is closed or the engine does not answer. Nothing here is
     * sent to the collector.
     */
    fun readSinkHealth(onResult: (SinkHealth?) -> Unit) {
        val queued = accepting && handler.post {
            val health = if (active) guarded("health") { querySinkHealth() } else null
            guarded("health callback") { onResult(health) }
        }
        if (!queued) guarded("health callback") { onResult(null) }
    }

    private fun querySinkHealth(): SinkHealth? {
        val response = transport.submit("""{"type":"engine.health","input":{}}""".toByteArray(Charsets.UTF_8))
        if (response.status != EngineStatus.OK) return null
        val sinks = JSONObject(response.text()).getJSONObject("result").getJSONObject("health").getJSONObject("sinks")
        return SinkHealth(sinks.getLong("pending"), sinks.getLong("accepted"), sinks.getLong("dropped"))
    }

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
     * effects are dropped except `frame.release`, the one effect that only
     * frees host memory: no new IO, timer, or capture starts. An engine
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
            .filterIsInstance<Effect.FrameRelease>()
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

        /**
         * Starts a host on a new `tugboat-engine` thread; the host owns
         * [transport] and closes [http] at shutdown.
         */
        fun start(
            transport: EngineTransport,
            frames: FrameHandleTable,
            http: HttpSender,
            captures: CaptureRequestSink,
            scenes: SceneWatchSink = SceneWatchSink.NONE,
        ): EngineHost {
            val thread = HandlerThread("tugboat-engine", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
            return EngineHost(
                transport = transport,
                handler = Handler(thread.looper),
                http = http,
                frames = frames,
                onShutDown = { thread.quitSafely() },
                captures = captures,
                scenes = scenes,
            )
        }
    }
}
