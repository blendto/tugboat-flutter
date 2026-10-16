package com.tugboat.android.host

import org.json.JSONObject

/**
 * The fields of a `capture.request` effect the host acts on
 * (stateful-engine.md section 8.2). The others are the engine's
 * bookkeeping: it already waited out `notBeforeMonoUs` and applied
 * `dropWhenBusy`, checks `context` itself when the answer arrives, and
 * `requireFreshPaint` needs nothing more here because the pixel runtime
 * always copies a frame committed after the request reached it.
 */
internal data class CaptureRequestEffect(
    /** `capture-N`; the `capture.result` echoes it. */
    val requestId: String,
    /** Capture even when the paint is unchanged; never answered `paintUnchanged`. */
    val force: Boolean,
    /** Multiplies the capture pixel ratio (the engine's `degradedScale` under budget pressure). */
    val scale: Double,
    val dHashBaseline: DHashBaseline?,
) {
    companion object {
        /** Throws [org.json.JSONException] when a required field is missing. */
        fun from(effect: JSONObject): CaptureRequestEffect {
            val baseline = effect.optJSONObject("dHashBaseline")?.let {
                DHashBaseline(it.getString("dHash"), it.getString("structureSignature"))
            }
            return CaptureRequestEffect(
                requestId = effect.getString("requestId"),
                force = effect.getBoolean("force"),
                scale = effect.optDouble("scale", 1.0).takeIf { it.isFinite() && it > 0 } ?: 1.0,
                dHashBaseline = baseline,
            )
        }
    }
}

/**
 * The perceptual baseline the engine offers: the last accepted frame's dHash
 * and the visible structure it was captured with. Opaque tokens.
 */
internal data class DHashBaseline(val dHash: String, val structureSignature: String)

/**
 * Performs `capture.request` effects. Called on the engine thread; it must
 * return at once and answer every request exactly once, by id, through
 * `capture.result` (C16: requests may overlap).
 */
internal fun interface CaptureRequestSink {
    fun onCaptureRequest(request: CaptureRequestEffect)

    companion object {
        /** Drops requests; the engine resolves each at its C18 answer deadline. For hosts that never capture. */
        val NONE = CaptureRequestSink { }
    }
}
