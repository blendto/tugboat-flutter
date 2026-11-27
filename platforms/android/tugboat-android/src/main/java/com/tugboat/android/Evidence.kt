package com.tugboat.android

import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.evidence.NetworkOutcome
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records your app's own events (for example analytics events) as
 * `external_event` evidence. Get one from [Tugboat.eventHook]; keep it as
 * long as you like. Each [record] goes to the session running at that
 * moment, and is ignored while Tugboat is not started.
 */
class EventHook internal constructor(
    private val source: String?,
    private val policy: ParameterPolicy,
    private val recorder: () -> EvidenceRecorder?,
) {
    /**
     * Records one event, for example `record("USER_LOGIN", mapOf("method" to "email"))`.
     * Callable from any thread. The time is taken here, the [ParameterPolicy]
     * transform (if any) runs here, and [parameters] are read before this
     * returns, so the caller may change the map afterwards. Never throws.
     *
     * Values may be JSON-like: `null`, strings, booleans, numbers, and maps
     * and lists (also arrays) of them. Anything else is recorded as
     * unsupported, never by its `toString`.
     */
    @JvmOverloads
    fun record(name: String, parameters: Map<String, Any?>? = null) {
        Tugboat.guarded("record") { recorder()?.recordExternalEvent(name, source, policy, parameters) }
    }
}

/** Why a [NetworkCall] did not get a response. */
enum class NetworkFailure {
    /** The request failed in transport: no response arrived. */
    NETWORK_ERROR,

    /** The request was cancelled before a response arrived. */
    CANCELLED,
}

/**
 * One logical HTTP call, begun with [Tugboat.beginNetworkCall]. Finish it
 * once with [complete] or [fail]; a second finish of either kind is
 * ignored. Callable from any thread; never throws.
 *
 * The SDK never reads URLs, query strings, headers, or request bodies: only
 * what you pass here.
 */
class NetworkCall internal constructor(
    private val recorder: EvidenceRecorder?,
    private val begun: EvidenceRecorder.BegunCall?,
) {
    private val finished = AtomicBoolean(false)

    /**
     * A response arrived with [statusCode]. [errorResponseBody] is kept only
     * when [statusCode] is 400 or more, bounded: a `String` is text; a `Map`
     * or `List` is JSON; a `ByteArray` (or any other binary) is not kept.
     * [attemptCount] is the number of attempts, retries included, when you
     * know it.
     */
    @JvmOverloads
    fun complete(statusCode: Int? = null, attemptCount: Int? = null, errorResponseBody: Any? = null) =
        finish(NetworkOutcome.Response, statusCode, attemptCount, errorResponseBody)

    /** No response arrived, because of [failure]. The other arguments are as for [complete]. */
    @JvmOverloads
    fun fail(failure: NetworkFailure, statusCode: Int? = null, attemptCount: Int? = null, errorResponseBody: Any? = null) =
        finish(NetworkOutcome.of(failure), statusCode, attemptCount, errorResponseBody)

    private fun finish(outcome: NetworkOutcome, statusCode: Int?, attemptCount: Int?, errorResponseBody: Any?) {
        Tugboat.guarded("network call") {
            val recorder = recorder ?: return@guarded
            val call = begun ?: return@guarded
            val end = recorder.now()
            if (!finished.compareAndSet(false, true)) return@guarded
            recorder.finishNetworkCall(call, end, outcome, statusCode, attemptCount, errorResponseBody)
        }
    }

    internal companion object {
        /** For calls that are not recorded: not started, stopped, disabled, or no route. */
        val NOOP = NetworkCall(null, null)
    }
}
