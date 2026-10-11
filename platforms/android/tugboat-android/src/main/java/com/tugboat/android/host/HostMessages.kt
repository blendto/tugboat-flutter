package com.tugboat.android.host

import org.json.JSONException
import org.json.JSONObject

/**
 * Builds the JSON messages the host submits. Caller messages are edited as
 * text, never re-encoded, so their numbers and key order reach the engine
 * unchanged.
 */
internal object HostMessages {
    /**
     * [message] with `"at"` set to [at], unless it already has a top-level
     * `at`. Text that is not a JSON object is returned unchanged so the
     * engine reports it.
     */
    fun stamped(message: String, at: HostTime): String {
        val members = try {
            RawJson.members(message)
        } catch (malformed: JSONException) {
            return message
        }
        if ("at" in members) return message
        val open = message.indexOf('{') + 1
        val separator = if (members.isEmpty()) "" else ","
        return message.substring(0, open) + "\"at\":" + at.toJson() + separator + message.substring(open)
    }

    /** One `batch` message applying [messages] in order. */
    fun batch(messages: List<String>): String =
        messages.joinToString(separator = ",", prefix = "{\"type\":\"batch\",\"messages\":[", postfix = "]}")

    fun timerFired(timerId: String): String =
        "{\"type\":\"timer.fired\",\"input\":{\"timerId\":${JSONObject.quote(timerId)}}}"

    /** `transport.result` echoing the effect's raw `requestId`. */
    fun transportResult(requestIdJson: String, outcome: TransportOutcome): String {
        val input = StringBuilder("{\"requestId\":").append(requestIdJson).append(",\"outcome\":")
        when (outcome) {
            is TransportOutcome.Http -> input.append("\"http\",\"status\":").append(outcome.status)
                .append(",\"body\":").append(JSONObject.quote(outcome.body))
            TransportOutcome.Error -> input.append("\"error\"")
            TransportOutcome.Timeout -> input.append("\"timeout\"")
        }
        input.append('}')
        return "{\"type\":\"transport.result\",\"input\":$input}"
    }
}
