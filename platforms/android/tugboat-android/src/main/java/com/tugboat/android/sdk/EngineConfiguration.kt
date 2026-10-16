package com.tugboat.android.sdk

import com.tugboat.android.TugboatConfig
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONObject

/**
 * The `engine.configure` input (stateful-engine.md section 6). Groups the
 * SDK sets explicitly; everything else keeps the engine's Dart defaults.
 *
 * - `host`: [HostMetadata], every field `session_start` needs.
 * - `limits`: the Dart defaults, stated so a changed engine default cannot
 *   silently change native sessions.
 * - `gesture`: the Views adapter's `ViewConfiguration` slops in dp, so the
 *   engine and the adapter's tap check agree.
 * - `capture.answerTimeoutMs`: the C18 deadline for a `capture.result`.
 * - `collector.enabled`: the engine owns delivery; the host only performs
 *   `http.send`.
 * - `capabilities`: focus and system input from [TugboatConfig].
 */
internal object EngineConfiguration {
    const val MAX_EVENTS = 5000
    const val MAX_FRAMES = 500
    const val MAX_SCROLL_SAMPLES = 200
    const val CAPTURE_ANSWER_TIMEOUT_MS = 5000

    fun build(config: TugboatConfig, host: HostMetadata, gesture: GestureConfig): JSONObject =
        JSONObject()
            .put("host", host.hostJson())
            .put(
                "limits",
                JSONObject()
                    .put("maxEvents", MAX_EVENTS)
                    .put("maxFrames", MAX_FRAMES)
                    .put("maxScrollSamples", MAX_SCROLL_SAMPLES),
            )
            .put("gesture", gesture.toEngineJson())
            .put("capture", JSONObject().put("answerTimeoutMs", CAPTURE_ANSWER_TIMEOUT_MS))
            .put("collector", JSONObject().put("enabled", true))
            .put(
                "capabilities",
                JSONObject()
                    .put("focusChanges", config.captureFocusChanges)
                    .put("systemInput", config.captureSystemInput),
            )
}
