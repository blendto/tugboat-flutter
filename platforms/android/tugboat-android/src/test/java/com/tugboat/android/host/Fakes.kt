package com.tugboat.android.host

import com.tugboat.android.engine.EngineResponse
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.engine.EngineTransport
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records every submitted message and answers from [responses] (one per
 * submit, in order), then with an empty `ok` response.
 */
internal class FakeEngineTransport(vararg responses: EngineResponse) : EngineTransport {
    private val queued = ArrayDeque(responses.toList())
    private val inSubmit = AtomicBoolean(false)

    val submitted = CopyOnWriteArrayList<String>()
    val submitThreads = CopyOnWriteArrayList<Thread>()
    var overlappingSubmits = 0
    var closed = false
    var throwOnSubmit: RuntimeException? = null

    fun enqueue(response: EngineResponse) = queued.addLast(response)

    override fun submit(message: ByteArray): EngineResponse {
        if (!inSubmit.compareAndSet(false, true)) overlappingSubmits++
        try {
            submitted += message.toString(Charsets.UTF_8)
            submitThreads += Thread.currentThread()
            throwOnSubmit?.let { throw it }
            return queued.removeFirstOrNull() ?: ok()
        } finally {
            inSubmit.set(false)
        }
    }

    override fun close() {
        closed = true
    }
}

internal fun ok(vararg effects: String): EngineResponse = response(
    EngineStatus.OK,
    "{\"type\":\"test\",\"records\":[],\"effects\":[${effects.joinToString(",")}]}",
)

internal fun response(status: EngineStatus, json: String): EngineResponse =
    EngineResponse(status.code, json.toByteArray(Charsets.UTF_8))

internal fun failure(status: EngineStatus): EngineResponse =
    response(status, "{\"error\":{\"status\":\"${status.wireName}\",\"message\":\"test\"}}")

/** Records requests; answers only when the test calls [complete]. */
internal class FakeHttpSender(private val frames: FrameHandleTable? = null) : HttpSender {
    val requests = CopyOnWriteArrayList<HttpRequest>()

    /** Whether each request's frame handles were still in the table when sent. */
    val framesPresentAtSend = CopyOnWriteArrayList<Boolean>()
    private val callbacks = CopyOnWriteArrayList<(TransportOutcome) -> Unit>()
    var closed = false

    override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
        requests += request
        callbacks += onResult
        val multipart = request.body as? HttpBody.Multipart
        if (frames != null && multipart != null) {
            framesPresentAtSend += multipart.frames.all { frames[it.handle] != null }
        }
    }

    fun complete(index: Int, outcome: TransportOutcome) = callbacks[index](outcome)

    override fun close() {
        closed = true
    }
}

internal class FakeClock(var monoUs: Long = 1_000_000, var wallUs: Long = 1_791_712_345_678_901) : HostClock {
    override fun now(): HostTime = HostTime(monoUs, wallUs)
}
