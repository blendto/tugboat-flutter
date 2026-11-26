package com.tugboat.android.capture

import org.json.JSONObject

/**
 * The engine's `surface {boundaryRect, generation}` fact
 * (stateful-engine.md 8.2): the capture boundary in dp and the boundary
 * transform generation, which advances whenever the rect changes (rotation,
 * multi-window resize). The first rect keeps generation 0, the generation
 * the engine's first (`initial`) capture request already carries, so that
 * capture is not made stale by the first report. Main thread only.
 */
internal class SurfaceReporter(private val post: (inputJson: String) -> Unit) {
    private var last: BoundaryRect? = null
    private var generation = 0L

    /** Posts a `surface` fact when [rect] differs from the last one reported. */
    fun observe(rect: BoundaryRect) {
        val previous = last
        if (previous == rect) return
        if (previous != null) generation++
        last = rect
        post(JSONObject().put("boundaryRect", rect.toJson()).put("generation", generation).toString())
    }

    companion object {
        const val FACT_TYPE = "surface"
    }
}
