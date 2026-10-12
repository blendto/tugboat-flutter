package com.tugboat.android.sdk

import android.util.Log
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.HttpSender
import com.tugboat.android.host.TransportOutcome
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * An [HttpSender] that notices when the session's `session_end` lifecycle
 * post is settled, so `stop()` can dispose the engine without cutting off
 * its drain (C5): the engine holds `session_end` until frames and events
 * drained or `endDrainTimeoutMs` passed, and `engine.dispose` starts no new
 * IO. Settled means accepted (202) or dropped for good (a status the
 * engine does not retry); a retried outcome keeps waiting.
 */
internal class SessionEndWatcher(private val delegate: HttpSender) : HttpSender {
    private val settled = AtomicBoolean(false)

    private val onSettled = AtomicReference<(() -> Unit)?>()

    override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
        val sessionEnd = isSessionEnd(request)
        delegate.send(request) { outcome ->
            try {
                onResult(outcome)
            } finally {
                if (sessionEnd && isFinal(outcome)) settle()
            }
        }
    }

    override fun close() = delegate.close()

    /** Runs [callback] once `session_end` settles (at once if it already has). */
    fun whenSettled(callback: () -> Unit) {
        onSettled.set(callback)
        if (settled.get()) fire()
    }

    private fun settle() {
        settled.set(true)
        fire()
    }

    private fun fire() {
        val callback = onSettled.getAndSet(null) ?: return
        try {
            callback()
        } catch (failure: Throwable) {
            Log.w(TAG, "stop callback failed", failure)
        }
    }

    companion object {
        private const val TAG = "TugboatStop"

        fun isSessionEnd(request: HttpRequest): Boolean {
            if (request.lane != "lifecycle") return false
            val body = request.body as? HttpBody.Json ?: return false
            return try {
                JSONObject(body.text).optString("eventType") == "session_end"
            } catch (_: Throwable) {
                false
            }
        }

        /** The engine retries 408, 429, 5xx, `error`, and `timeout`; anything else is final. */
        fun isFinal(outcome: TransportOutcome): Boolean =
            outcome is TransportOutcome.Http &&
                outcome.status != 408 && outcome.status != 429 && outcome.status !in 500..599
    }
}
