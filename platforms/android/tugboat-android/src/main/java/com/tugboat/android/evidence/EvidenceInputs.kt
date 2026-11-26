package com.tugboat.android.evidence

import com.tugboat.android.NetworkFailure
import com.tugboat.android.ParameterPolicy

/**
 * Encodes evidence for the engine: the one seam between typed Kotlin values
 * and the engine's input value encoding. Both calls run on the thread that
 * recorded the evidence and may throw (the caller drops the evidence).
 */
internal interface EvidenceEncoder {
    /** The `evidence.externalEvent` input object. */
    fun externalEvent(event: ExternalEventInput): String

    /** The `evidence.networkCall` input object. */
    fun networkCall(call: NetworkCallInput): String
}

/**
 * One [com.tugboat.android.EventHook.record], as passed: nothing is bounded
 * or applied here. [parameters] is the host's map; the encoder reads it and
 * runs a transform [policy]'s function (on the recording thread).
 */
internal class ExternalEventInput(
    val name: String,
    val source: String?,
    val policy: ParameterPolicy,
    val parameters: Map<*, *>?,
    val atMonoUs: Long,
)

internal enum class NetworkOutcome {
    Response,
    NetworkError,
    Cancelled;

    companion object {
        fun of(failure: NetworkFailure) = when (failure) {
            NetworkFailure.NETWORK_ERROR -> NetworkError
            NetworkFailure.CANCELLED -> Cancelled
        }
    }
}

/**
 * One finished [com.tugboat.android.NetworkCall], as passed: [method],
 * [route], and [errorResponseBody] are not bounded here. The encoder never
 * reads the body of a status below 400.
 */
internal class NetworkCallInput(
    val method: String,
    val route: String,
    val startMonoUs: Long,
    val endMonoUs: Long,
    val statusCode: Int?,
    val outcome: NetworkOutcome,
    val attemptCount: Int?,
    val errorResponseBody: Any?,
)
