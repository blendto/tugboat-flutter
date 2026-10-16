package com.tugboat.android.evidence

import com.tugboat.android.NetworkFailure
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.ParameterTransform

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
 * One [com.tugboat.android.EventHook.record], as passed: [name] and [source]
 * are not bounded here. [parameters] is the host's map, except under a
 * transform policy, where it is a copy holding each key's transformed value
 * or [ParameterPolicy.DROP].
 */
internal class ExternalEventInput(
    val name: String,
    val source: String?,
    val policy: PolicyInput,
    val parameters: Map<*, *>?,
    val atMonoUs: Long,
)

/** The parameter policy the engine applies. */
internal class PolicyInput(val mode: ParameterPolicy.Mode, val allowedKeys: Set<String>?) {
    companion object {
        fun of(policy: ParameterPolicy) = PolicyInput(
            policy.mode,
            policy.allowedKeys.takeIf { policy.mode == ParameterPolicy.Mode.AllowList },
        )

        /**
         * Runs a transform policy's function over [parameters]' top-level
         * entries, in their order. A key that is not a `String` (possible from
         * Java) is never passed to the function: its value is dropped. A
         * function that throws drops that key's value. Other policies return
         * [parameters] unchanged.
         */
        fun prepare(policy: ParameterPolicy, parameters: Map<*, *>?): Map<*, *>? {
            val transform = policy.transform
            if (policy.mode != ParameterPolicy.Mode.Transform || transform == null || parameters == null) {
                return parameters
            }
            val out = LinkedHashMap<Any?, Any?>(parameters.size)
            for ((key, value) in parameters) {
                out[key] = if (key is String) transformed(transform, key, value) else ParameterPolicy.DROP
            }
            return out
        }

        private fun transformed(transform: ParameterTransform, key: String, value: Any?): Any? =
            try {
                transform.apply(key, value)
            } catch (_: Throwable) {
                ParameterPolicy.DROP
            }
    }
}

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
 * [route], and [errorResponseBody] are not bounded here, and the body is
 * passed whatever the status.
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
