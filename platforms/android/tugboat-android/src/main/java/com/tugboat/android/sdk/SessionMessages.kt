package com.tugboat.android.sdk

import org.json.JSONObject

/** Inputs of the session, lifecycle, and identity messages the SDK sends (stateful-engine.md 4.2, README vocabulary). */
internal object SessionMessages {
    const val ENGINE_CONFIGURE = "engine.configure"
    const val SESSION_START = "session.start"
    const val SESSION_END = "session.end"
    const val APP_LIFECYCLE = "app.lifecycle"
    const val IDENTITY_SET = "identity.set"
    const val TRAITS_SET = "traits.set"
    const val LOCALE_SET = "locale.set"

    fun sessionStart(
        device: DeviceSnapshot,
        host: HostMetadata,
        sessionEpoch: Int,
        activationRequestId: String? = null,
        explorationRunId: String? = null,
    ): String =
        JSONObject()
            .put("viewport", JSONObject().put("width", device.screenWidthDp).put("height", device.screenHeightDp))
            .put("platform", HostMetadata.PLATFORM)
            .put("sessionEpoch", sessionEpoch)
            .put("locale", host.sessionLocaleJson())
            .also { json ->
                activationRequestId?.let { json.put("activationRequestId", it) }
                explorationRunId?.let { json.put("explorationRunId", it) }
            }
            .toString()

    fun localeSet(locale: org.json.JSONObject): String = JSONObject().put("locale", locale).toString()

    fun sessionEnd(): String = JSONObject().put("reason", "session_end").toString()

    /** [state]: `paused`, `hidden`, `inactive`, `resumed`, or `detached`. */
    fun appLifecycle(state: String): String = JSONObject().put("state", state).toString()

    fun identity(userId: String?): String = JSONObject().put("userId", userId ?: JSONObject.NULL).toString()

    /** Throws [org.json.JSONException] for values JSON cannot carry (NaN, infinities). */
    fun traits(traits: Map<String, Any?>): String = JSONObject().put("traits", JSONObject(traits)).toString()
}
