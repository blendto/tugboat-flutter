package com.tugboat.android.views.scroll

import android.view.View
import com.tugboat.android.host.HostTime
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.ScrollMetrics
import com.tugboat.android.views.identity.TargetAnchor
import org.json.JSONObject
import java.util.WeakHashMap

/** Engine `scroll.phase` values. */
internal enum class ScrollPhase(val wire: String) {
    Start("start"),
    Update("update"),
    End("end"),
    Overscroll("overscroll"),
}

/**
 * Builds `scroll {scrollableId, phase, offset?, axis?, maxScrollExtent?,
 * anchor?}` facts (stateful-engine.md 9.1). Offsets and extents are logical
 * pixels (dp). `overscroll` carries only the id; `anchor` only `start`.
 */
internal object ScrollFacts {
    fun fact(
        id: String,
        phase: ScrollPhase,
        metrics: ScrollMetrics?,
        density: Float,
        at: HostTime,
        anchor: TargetAnchor? = null,
    ): ViewsFact {
        val input = JSONObject().put("scrollableId", id).put("phase", phase.wire)
        if (phase != ScrollPhase.Overscroll && metrics != null) {
            val scale = density.toDouble().takeIf { it > 0 } ?: 1.0
            input.put("offset", metrics.offsetPx / scale).put("axis", metrics.axis.wire)
            metrics.maxExtentPx?.let { input.put("maxScrollExtent", it / scale) }
            if (phase == ScrollPhase.Start) anchor?.let { input.put("anchor", it.toJson()) }
        }
        return ViewsFact(FactTypes.SCROLL, input, at)
    }
}

/** Stable opaque `scrollableId`s: one per scrollable instance, for its lifetime. */
internal object ScrollableIds {
    private val ids = WeakHashMap<View, String>()
    private var next = 1L

    fun of(view: View): String = synchronized(ids) { ids.getOrPut(view) { "view-scroll-${next++}" } }
}
