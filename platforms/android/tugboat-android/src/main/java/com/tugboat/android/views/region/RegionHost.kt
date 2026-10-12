package com.tugboat.android.views.region

import android.app.Activity
import android.view.View
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
 * (the host is anchored), masks mean the whole frame.
 */
internal class RegionHost(val view: View, val region: ToolkitRegion) {
    fun targetAt(x: Float, y: Float): RegionHit =
        AdapterGuard.run("region target", RegionHit.Unreadable) { region.targetAt(view, x, y) }

    fun scrollables(): List<RegionScrollable> =
        AdapterGuard.run("region scrollables", emptyList()) { region.scrollables(view) }

    fun masks(): RegionMasks = AdapterGuard.run("region masks", RegionMasks.WHOLE_FRAME) { region.masks(view) }

    fun focus(): RegionFocus? = AdapterGuard.run("region focus", null) { region.focus(view) }

    fun routeKey(): String? = AdapterGuard.run("region route", null) { region.routeKey(view) }
}

/** Looks up region hosts among the registered [ToolkitRegions]. */
internal object Regions {
    /** The region host [view] is, or null. */
    fun hostOf(view: View): RegionHost? {
        val regions = ToolkitRegions.all
        if (regions.isEmpty()) return null
        val region = AdapterGuard.run("region lookup", null) { regions.firstOrNull { it.hosts(view) } }
        return region?.let { RegionHost(view, it) }
    }

    /** The nearest region host from [view] up to [stop], both included, or null. */
    fun enclosing(view: View, stop: View): RegionHost? {
        if (ToolkitRegions.all.isEmpty()) return null
        var current: View? = view
        while (current != null) {
            hostOf(current)?.let { return it }
            if (current === stop) return null
            current = current.parent as? View
        }
        return null
    }

    /** Forwards the `trackNavigation` hook to every region. */
    fun onDestinationChanged(activity: Activity, route: String?) {
        for (region in ToolkitRegions.all) {
            AdapterGuard.run("region destination") { region.onDestinationChanged(activity, route) }
        }
    }
}
