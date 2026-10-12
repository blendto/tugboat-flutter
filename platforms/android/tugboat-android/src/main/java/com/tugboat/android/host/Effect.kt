package com.tugboat.android.host

import android.util.Log
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** An effect request from an engine response (stateful-engine.md section 3.1). */
internal sealed interface Effect {
    data class TimerSchedule(val timerId: String, val atMonoUs: Long) : Effect

    data class TimerCancel(val timerId: String) : Effect

    data class HttpSend(val request: HttpRequest) : Effect

    data class FrameRelease(val handle: String) : Effect

    data class CaptureRequest(val request: CaptureRequestEffect) : Effect

    /** A type this host does not execute; logged once and ignored. */
    data class Unknown(val type: String) : Effect
}

/** Turns the `effects` array of an engine response into [Effect]s. */
internal object EffectParser {
    private const val TAG = "TugboatEngine"

    private val parsers: Map<String, (JSONObject) -> Effect> = mapOf(
        "timer.schedule" to ::timerSchedule,
        "timer.cancel" to ::timerCancel,
        "http.send" to ::httpSend,
        "frame.release" to ::frameRelease,
        "capture.request" to { effect -> Effect.CaptureRequest(CaptureRequestEffect.from(effect)) },
    )

    /**
     * Effects of a response, in order. A response without `effects` has
     * none; an effect that breaks its schema is logged and skipped.
     * Throws [JSONException] when [response] is not a JSON object.
     */
    fun parse(response: String): List<Effect> {
        val effects = JSONObject(response).optJSONArray("effects") ?: return emptyList()
        return (0 until effects.length()).mapNotNull { parseEffect(effects, it) }
    }

    private fun parseEffect(effects: JSONArray, index: Int): Effect? =
        try {
            val effect = effects.getJSONObject(index)
            val type = effect.getString("type")
            parsers[type]?.invoke(effect) ?: Effect.Unknown(type)
        } catch (error: JSONException) {
            Log.w(TAG, "dropping malformed effect $index: ${error.message}")
            null
        }

    private fun timerSchedule(effect: JSONObject): Effect =
        Effect.TimerSchedule(effect.getString("timerId"), effect.getLong("atMonoUs"))

    private fun timerCancel(effect: JSONObject): Effect = Effect.TimerCancel(effect.getString("timerId"))

    private fun frameRelease(effect: JSONObject): Effect = Effect.FrameRelease(effect.getString("handle"))

    private fun httpSend(effect: JSONObject): Effect {
        val body = when {
            effect.has("jsonBody") -> HttpBody.Json(effect.getString("jsonBody"))
            effect.has("multipart") -> multipart(effect.getJSONObject("multipart"))
            else -> throw JSONException("http.send needs jsonBody or multipart")
        }
        val request = HttpRequest(
            requestId = effect.getString("requestId"),
            lane = effect.getString("lane"),
            path = effect.getString("path"),
            timeoutMs = effect.getInt("timeoutMs"),
            body = body,
        )
        return Effect.HttpSend(request)
    }

    private fun multipart(multipart: JSONObject): HttpBody.Multipart {
        val fields = multipart.getJSONArray("fields").mapItems { fields, i ->
            val pair = fields.getJSONArray(i)
            if (pair.length() != 2) throw JSONException("multipart field $i is not a [name, value] pair")
            pair.getString(0) to pair.getString(1)
        }
        val frames = multipart.getJSONArray("frames").mapItems { frames, i ->
            val frame = frames.getJSONObject(i)
            FramePart(frame.getString("handle"), frame.getString("filename"))
        }
        return HttpBody.Multipart(fields, frames)
    }

    private inline fun <T> JSONArray.mapItems(item: (JSONArray, Int) -> T): List<T> =
        (0 until length()).map { item(this, it) }
}
