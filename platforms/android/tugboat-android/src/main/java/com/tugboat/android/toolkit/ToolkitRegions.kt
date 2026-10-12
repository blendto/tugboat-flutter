package com.tugboat.android.toolkit

import java.util.concurrent.CopyOnWriteArrayList

/**
 * The registered toolkit regions. A toolkit module registers its region once
 * when installed; the Views adapter reads the list on the main thread.
 */
@TugboatToolkitApi
object ToolkitRegions {
    private val regions = CopyOnWriteArrayList<ToolkitRegion>()

    /** Registers [region]; registering the same instance again does nothing. */
    fun register(region: ToolkitRegion) {
        regions.addIfAbsent(region)
    }

    fun unregister(region: ToolkitRegion) {
        regions.remove(region)
    }

    internal val all: List<ToolkitRegion>
        get() = regions
}
