package com.tugboat.android.evidence

import com.tugboat.android.NetworkCall
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime

/**
 * Turns [com.tugboat.android.EventHook.record] and [NetworkCall] calls into
 * `evidence.externalEvent` and `evidence.networkCall` messages for one
 * running engine.
 *
 * The engine does the bounding and the policy: limits, label bounds, the
 * `namesOnly` / `allowList` rules, the error-body rule (status 400 or more),
 * method and route validity, and `durationMs`
 * (`core/session-engine/docs/evidence-messages.md`). This class takes the
 * time, keeps the one-finish rule, and hands typed values to the [encoder]
 * (which runs a transform policy's function) on the calling thread.
 * Every method may be called from any thread; the time is taken on the
 * calling thread and [post] is the engine host's any-thread submission path.
 */
internal class EvidenceRecorder(
    private val clock: HostClock,
    private val encoder: EvidenceEncoder,
    /** `EngineHost.isRunning`: false once the host closed or disabled itself. */
    private val hostRunning: () -> Boolean,
    private val post: (type: String, inputJson: String, at: HostTime) -> Unit,
) {
    @Volatile
    private var closed = false

    /** Whether new evidence is taken. */
    val isAccepting: Boolean
        get() = !closed && hostRunning()

    /** Called when the session ends: later evidence, finishes of earlier calls included, is ignored. */
    fun close() {
        closed = true
    }

    fun now(): HostTime = clock.now()

    fun recordExternalEvent(name: String, source: String?, policy: ParameterPolicy, parameters: Map<*, *>?) {
        val at = clock.now()
        if (!isAccepting) return
        val event = ExternalEventInput(
            name = name,
            source = source,
            policy = policy,
            parameters = parameters,
            atMonoUs = at.monoUs,
        )
        post(EvidenceMessages.EXTERNAL_EVENT, encoder.externalEvent(event), at)
    }

    /** A no-op call when not accepting or when [route] is null or blank (the engine bounds the rest). */
    fun beginNetworkCall(method: String, route: String?): NetworkCall {
        val start = clock.now()
        if (route.isNullOrBlank() || !isAccepting) return NetworkCall.NOOP
        return NetworkCall(this, BegunCall(method, route, start.monoUs))
    }

    fun finishNetworkCall(
        call: BegunCall,
        end: HostTime,
        outcome: NetworkOutcome,
        statusCode: Int?,
        attemptCount: Int?,
        errorResponseBody: Any?,
    ) {
        if (!isAccepting) return
        val input = NetworkCallInput(
            method = call.method,
            route = call.route,
            startMonoUs = call.startMonoUs,
            endMonoUs = end.monoUs,
            statusCode = statusCode,
            outcome = outcome,
            attemptCount = attemptCount,
            errorResponseBody = errorResponseBody,
        )
        post(EvidenceMessages.NETWORK_CALL, encoder.networkCall(input), end)
    }

    /** What [beginNetworkCall] keeps until the call finishes. */
    class BegunCall(val method: String, val route: String, val startMonoUs: Long)
}

/** The engine messages this package sends. */
internal object EvidenceMessages {
    const val EXTERNAL_EVENT = "evidence.externalEvent"
    const val NETWORK_CALL = "evidence.networkCall"
}
