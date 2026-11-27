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
    /** `initial`, `tap`, `scroll`, `route`, `lifecycle`, `manual` or `interaction`. */
    val trigger: String = "manual",
    /** With `nativeSceneInventory`, on an `interaction` capture: `tap`, `gesture` or `scroll`. */
    val inventoryTrigger: String? = null,
) {
    /**
     * The `scene_inventory.trigger` of the inventory sent for this capture's frame
     * (stateful-engine.md section 4.3.2): the engine's label for an interaction,
     * else the capture trigger (`lifecycle` is `resume`).
     */
    val sceneTrigger: String
        get() = inventoryTrigger ?: when (trigger) {
            "lifecycle" -> "resume"
            "interaction" -> "gesture"
            else -> trigger
        }

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
                trigger = effect.optString("trigger", "manual"),
                inventoryTrigger = effect.optString("inventoryTrigger", "").takeIf { it.isNotEmpty() },
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
 * Runs the settled re-sample watch the engine asks for
 * (stateful-engine.md section 4.3.2). Called on the engine thread; it must
 * return at once.
 */
internal interface SceneWatchSink {
    /** `scene.watch`: start (`true`) or stop reporting drawn frames. */
    fun onSceneWatch(armed: Boolean)

    /** `scene.sample`: build the visible route's inventory and send it as a re-sample answer. */
    fun onSceneSample()

    companion object {
        val NONE = object : SceneWatchSink {
            override fun onSceneWatch(armed: Boolean) = Unit

            override fun onSceneSample() = Unit
        }
    }
}

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
