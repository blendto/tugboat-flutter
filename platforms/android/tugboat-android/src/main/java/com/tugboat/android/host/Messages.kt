package com.tugboat.android.host

import org.json.JSONObject

/**
 * One message for the engine: `{"type", "at"?, "input"}`.
 *
 * [inputJson] is the caller's encoded `input` object; the envelope is built
 * around it by concatenation, never re-encoded. [at] is the time the fact
 * happened; it is null only for messages the engine takes without one
 * (`engine.configure`, queries, stateless messages). [frameHandles] are the
 * frame-table handles the message hands to the engine: the host releases them
 * if the engine does not accept the message.
 */
internal class EngineMessage(
    val type: String,
    val inputJson: String,
    val at: HostTime?,
    val frameHandles: List<String> = emptyList(),
) {
    fun toJson(): String = buildString {
        append("{\"type\":").append(JSONObject.quote(type))
        if (at != null) append(",\"at\":").append(at.toJson())
        append(",\"input\":").append(inputJson).append('}')
    }

    companion object {
        /** One `batch` message applying [messages] in order, all or nothing. */
        fun batchJson(messages: List<EngineMessage>): String =
            messages.joinToString(separator = ",", prefix = "{\"type\":\"batch\",\"messages\":[", postfix = "]}") {
                it.toJson()
            }
    }
}

/** `input` objects of the messages the host itself sends. */
internal object HostMessages {
    const val TIMER_FIRED = "timer.fired"
    const val TRANSPORT_RESULT = "transport.result"

    /**
     * The last message before the handle is destroyed: the engine reports
     * undelivered work and becomes inert. Its input is empty.
     */
    const val ENGINE_DISPOSE = "engine.dispose"

    fun timerFiredInput(timerId: String): String = JSONObject().put("timerId", timerId).toString()

    fun transportResultInput(requestId: String, outcome: TransportOutcome): String {
        val input = JSONObject().put("requestId", requestId)
        when (outcome) {
            is TransportOutcome.Http -> input.put("outcome", "http").put("status", outcome.status).put("body", outcome.body)
            TransportOutcome.Error -> input.put("outcome", "error")
            TransportOutcome.Timeout -> input.put("outcome", "timeout")
        }
        return input.toString()
    }
}
