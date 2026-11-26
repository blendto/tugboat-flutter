package com.tugboat.android.views.mask

import com.tugboat.android.toolkit.MaskCoverageReason
import org.json.JSONArray
import org.json.JSONObject

/** How coarse one capture's masks are, coarsest wins. */
internal enum class MaskMode(val wire: String) {
    /** Every region and View was masked at its own bounds. */
    Precise("precise"),

    /** At least one region host was masked over its whole bounds. */
    WholeHost("wholeHost"),

    /** The whole frame is masked. */
    WholeFrame("wholeFrame"),
}

/**
 * Which masking actually applied to one capture, for the host to report per
 * frame on `capture.result` (no event fields): `{mode, reasons}` with
 * [MaskCoverageReason] wire names, sorted.
 */
internal data class MaskCoverage(val mode: MaskMode, val reasons: Set<MaskCoverageReason> = emptySet()) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("mode", mode.wire)
            .put("reasons", JSONArray(reasons.map { it.wire }.sorted()))

    /** The same mode, with [reason] among the reasons. */
    operator fun plus(reason: MaskCoverageReason): MaskCoverage = copy(reasons = reasons + reason)

    companion object {
        val PRECISE = MaskCoverage(MaskMode.Precise)

        fun wholeFrame(reason: MaskCoverageReason) = MaskCoverage(MaskMode.WholeFrame, setOf(reason))
    }
}
