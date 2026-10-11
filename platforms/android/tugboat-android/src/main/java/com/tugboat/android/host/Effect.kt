package com.tugboat.android.host

import android.util.Log
import org.json.JSONException
import org.json.JSONObject

/** An effect request from an engine response (stateful-engine.md section 3.1). */
internal sealed interface Effect {
    data class TimerSchedule(val timerId: String, val atMonoUs: Long) : Effect

    data class TimerCancel(val timerId: String) : Effect

    data class HttpSend(val request: HttpRequest) : Effect

    data class FrameRelease(val handle: String) : Effect

    /** A type this host does not execute; logged once and ignored. */
    data class Unknown(val type: String) : Effect
}

/** Turns the `effects` array of an engine response into [Effect]s. */
internal object EffectParser {
    private const val TAG = "TugboatEngine"

    private val parsers: Map<String, (EffectJson) -> Effect> = mapOf(
        "timer.schedule" to ::timerSchedule,
        "timer.cancel" to ::timerCancel,
        "http.send" to ::httpSend,
        "frame.release" to ::frameRelease,
    )

    /**
     * Effects of a response, in order. A response without `effects` has
     * none; an effect that breaks its schema is logged and skipped.
     */
    fun parse(response: String): List<Effect> {
        val effects = RawJson.members(response)["effects"] ?: return emptyList()
        return RawJson.elements(effects).mapNotNull(::parseEffect)
    }

    private fun parseEffect(raw: String): Effect? =
        try {
            val effect = EffectJson(raw)
            val type = effect.fields.getString("type")
            parsers[type]?.invoke(effect) ?: Effect.Unknown(type)
        } catch (error: JSONException) {
            Log.w(TAG, "dropping malformed effect: ${error.message}")
            null
        }

    private fun timerSchedule(effect: EffectJson): Effect =
        Effect.TimerSchedule(effect.fields.getString("timerId"), effect.fields.getLong("atMonoUs"))

    private fun timerCancel(effect: EffectJson): Effect = Effect.TimerCancel(effect.fields.getString("timerId"))

    private fun frameRelease(effect: EffectJson): Effect = Effect.FrameRelease(effect.fields.getString("handle"))

    private fun httpSend(effect: EffectJson): Effect {
        val raw = effect.raw
        val body = raw["json"]?.let(HttpBody::Json)
            ?: raw["multipart"]?.let(::multipart)
            ?: throw JSONException("http.send needs json or multipart")
        val request = HttpRequest(
            requestIdJson = raw["requestId"] ?: throw JSONException("http.send needs requestId"),
            lane = effect.fields.getString("lane"),
            path = effect.fields.getString("path"),
            timeoutMs = effect.fields.getInt("timeoutMs"),
            body = body,
        )
        return Effect.HttpSend(request)
    }

    private fun multipart(rawMultipart: String): HttpBody.Multipart {
        val raw = RawJson.members(rawMultipart)
        val fields = raw["fields"]?.let(RawJson::members).orEmpty().map { (name, value) ->
            // Strings are sent as their value; any other JSON as its text.
            name to if (value.startsWith('"')) RawJson.decodeString(value) else value
        }
        val frames = RawJson.elements(raw["frames"] ?: "[]").map { frame ->
            val json = JSONObject(frame)
            FramePart(json.getString("handle"), json.getString("filename"))
        }
        return HttpBody.Multipart(fields, frames)
    }

    /** One effect, decoded ([fields]) and as raw member text ([raw]). */
    private class EffectJson(text: String) {
        val fields = JSONObject(text)
        val raw: Map<String, String> by lazy { RawJson.members(text) }
    }
}
