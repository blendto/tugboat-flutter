package com.tugboat.android.views.identity

import org.json.JSONObject

/** `tap {anchor | failureReason}` evidence for a pointer-up (stateful-engine.md 9.1). */
internal class TapEvidence private constructor(val anchor: TargetAnchor?, val failureReason: String?) {
    fun toJson(): JSONObject =
        if (anchor != null) JSONObject().put("anchor", anchor.toJson()) else JSONObject().put("failureReason", failureReason)

    companion object {
        fun of(anchor: TargetAnchor) = TapEvidence(anchor, null)

        /** One of the engine's closed `TapFailureReason` names. */
        fun failed(reason: String) = TapEvidence(null, reason)

        const val NO_TARGET_AT_POINT = "no_target_at_point"
        const val NO_ACTIONABLE_CANDIDATE = "no_actionable_candidate"
        const val RESOLUTION_ERROR = "resolution_error"
    }
}
