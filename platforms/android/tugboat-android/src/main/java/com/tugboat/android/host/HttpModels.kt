package com.tugboat.android.host

/** One collector request from an `http.send` effect. */
internal data class HttpRequest(
    val requestId: String,
    val lane: String,
    val path: String,
    val timeoutMs: Int,
    val body: HttpBody,
)

internal sealed interface HttpBody {
    /** The engine's pre-encoded `jsonBody`, sent byte for byte. */
    data class Json(val text: String) : HttpBody

    /**
     * Form [fields] in engine order, then one `files` part per frame whose
     * JPEG bytes the host resolves from the frame handle table at send time.
     */
    data class Multipart(val fields: List<Pair<String, String>>, val frames: List<FramePart>) : HttpBody
}

internal data class FramePart(val handle: String, val filename: String)

/** What a request came to; becomes the `transport.result` input. */
internal sealed interface TransportOutcome {
    /** An HTTP response with a status in 100–599. [body] is at most [CollectorResponse.MAX_BODY_BYTES] UTF-8 bytes. */
    data class Http(val status: Int, val body: String) : TransportOutcome

    object Error : TransportOutcome

    object Timeout : TransportOutcome
}

/** Executes `http.send` effects off the engine thread. */
internal interface HttpSender {
    /**
     * Runs [request] asynchronously. [onResult] is called exactly once, from
     * any thread, whatever fails (a failure becomes [TransportOutcome.Error]).
     */
    fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit)

    fun close() {}
}
