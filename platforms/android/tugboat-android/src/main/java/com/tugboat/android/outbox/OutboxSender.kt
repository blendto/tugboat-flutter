package com.tugboat.android.outbox

import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.HttpSender
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.sdk.SessionEndWatcher

/**
 * The engine's [HttpSender] with the durable outbox in front (W11 design
 * 3.2). On the engine thread, at dispatch, each `http.send` is captured
 * (body bytes and frame byte references) and its entry write queued on the
 * outbox executor; the request starts at once, in parallel, carrying
 * `Tugboat-Delivery-Key`. An answer that ends the request (accepted or
 * dropped) queues the delete of its entries; a retried one keeps them. A
 * request whose key cannot be derived is sent as before, without an entry.
 */
internal class OutboxSender(
    private val delegate: HttpSender,
    private val outbox: Outbox,
    private val inputs: OutboxIdentityInputs,
    private val sdkVersion: String,
    /** JPEG bytes for a frame handle now; normally [com.tugboat.android.host.FrameHandleTable.get]. */
    private val frameBytes: (handle: String) -> ByteArray?,
    /** How long [close] waits for queued writes before closing [delegate]. */
    private val closeWaitMs: Long = CLOSE_WAIT_MS,
) : HttpSender {
    override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
        val captures = OutboxKeys.capture(request, frameBytes)
        val attempts = captures?.takeIf { it.isNotEmpty() }?.let(::record)
        if (captures == null || attempts == null) {
            outbox.unkeyed.incrementAndGet()
            delegate.send(request, onResult)
            return
        }
        val keys = captures.joinToString(",") { it.key }
        val keyed = request.copy(headers = request.headers + (OutboxKeys.HEADER to keys))
        delegate.send(keyed) { outcome ->
            try {
                onResult(outcome)
            } finally {
                settle(captures, attempts, outcome)
            }
        }
    }

    /** Marks [captures] in flight and queues their writes; null (nothing marked) if that fails. */
    private fun record(captures: List<OutboxCapture>): List<Long>? {
        val begun = ArrayList<Long>(captures.size)
        return try {
            outbox.noteSession(captures.first().sessionId)
            captures.forEach { begun += outbox.active.begin(it.key) }
            outbox.write(captures, inputs, sdkVersion)
            begun
        } catch (_: Throwable) {
            begun.forEachIndexed { index, attempt -> outbox.active.end(captures[index].key, attempt) }
            null
        }
    }

    /** Queued writes land before the executor below abandons queued requests (W11 design 3.2, `stop()`). */
    override fun close() {
        outbox.awaitQueued(closeWaitMs)
        delegate.close()
    }

    private fun settle(captures: List<OutboxCapture>, attempts: List<Long>, outcome: TransportOutcome) {
        val final = SessionEndWatcher.isFinal(outcome)
        captures.forEachIndexed { index, capture ->
            outbox.active.end(capture.key, attempts[index])
            if (final) outbox.deleteAnswered(capture.key, attempts[index])
        }
    }

    private companion object {
        const val CLOSE_WAIT_MS = 5_000L
    }
}
