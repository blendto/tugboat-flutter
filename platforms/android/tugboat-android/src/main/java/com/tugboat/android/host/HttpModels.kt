package com.tugboat.android.host

/**
 * One collector request from an `http.send` effect.
 *
 * [requestIdJson] is the effect's `requestId` as raw JSON; the host echoes it
 * verbatim in `transport.result`, whatever its JSON type.
 */
internal data class HttpRequest(
    val requestIdJson: String,
    val lane: String,
    val path: String,
    val timeoutMs: Int,
    val body: HttpBody,
)

internal sealed interface HttpBody {
    /** An engine-built JSON body, sent byte for byte. */
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
    /** Any HTTP response. [body] is at most [HttpExecutor.MAX_BODY_BYTES] bytes, decoded as UTF-8. */
    data class Http(val status: Int, val body: String) : TransportOutcome

    object Error : TransportOutcome

    object Timeout : TransportOutcome
}

/** Executes `http.send` effects off the engine thread. */
internal interface HttpSender {
    /** Runs [request] asynchronously; [onResult] is called exactly once, from any thread. */
    fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit)

    fun close() {}
}
