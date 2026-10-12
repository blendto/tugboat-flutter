package com.tugboat.android.views.region

import android.os.Looper
import android.view.View
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.toolkit.ToolkitRegion
import com.tugboat.android.toolkit.ToolkitRegions
import com.tugboat.android.views.AdapterGuard

/**
 * A region host view and the region that reads it. Every call into the
 * region is guarded and fails closed: no target means [RegionHit.Unreadable]
 * (the host is anchored); masks mean the whole frame, also off the main
 * thread, where no View tree may be read.
 */
internal class RegionHost(val view: View, val region: ToolkitRegion) {
    fun targetAt(x: Float, y: Float): RegionHit =
        AdapterGuard.run("region target", RegionHit.Unreadable) { region.targetAt(view, x, y) }

    fun scrollablesAt(x: Float, y: Float): List<RegionScrollable> =
        AdapterGuard.run("region scrollables", emptyList()) { region.scrollablesAt(view, x, y) }

    fun masks(): RegionMasks {
        if (Looper.myLooper() != Looper.getMainLooper()) return UNREADABLE
        return AdapterGuard.run("region masks", UNREADABLE) { region.masks(view) }
    }

    fun focus(): RegionFocus? = AdapterGuard.run("region focus", null) { region.focus(view) }

    private companion object {
        val UNREADABLE = RegionMasks.WholeFrame(MaskCoverageReason.WalkExhausted)
    }
}

/** Looks up region hosts among the registered [ToolkitRegions]. */
internal object Regions {
    /** True when any region is registered; callers skip region work otherwise. */
    val any: Boolean
        get() = ToolkitRegions.all.isNotEmpty()

    /** The region hosting [view], or null. Allocation-free: asked for every view of a walk. */
    fun regionOf(view: View): ToolkitRegion? {
        val regions = ToolkitRegions.all
        if (regions.isEmpty()) return null
        return AdapterGuard.run("region lookup", null) { regions.firstOrNull { it.hosts(view) } }
    }

    /** The region host [view] is, or null. */
    fun hostOf(view: View): RegionHost? = regionOf(view)?.let { RegionHost(view, it) }

    /** The nearest region host from [view] up to [stop], both included, or null. */
    fun enclosing(view: View, stop: View): RegionHost? {
        if (!any) return null
        var current: View? = view
        while (current != null) {
            hostOf(current)?.let { return it }
            if (current === stop) return null
            current = current.parent as? View
        }
        return null
    }
}
