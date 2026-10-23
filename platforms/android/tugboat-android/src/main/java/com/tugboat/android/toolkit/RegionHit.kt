package com.tugboat.android.toolkit

import android.graphics.RectF

/** The answer to [ToolkitRegion.targetAt]. */
@TugboatToolkitApi
sealed class RegionHit {
    /**
     * A target inside the region. The Views adapter prefixes [path] with
     * the host's own canonical path, hashes it with the route key, and
     * serializes it with the region's `toolkit`.
     */
    class Target(
        /** Canonical path segments below the host (`Button#0`, `[item:3]`). Never visible text. */
        val path: List<String>,
        val widgetType: String,
        /** The shared anchor role vocabulary (`button`, `textField`, ...), or null. */
        val role: String?,
        /** Sorted shared action names (`tap`, `longPress`, `input`, `slide`, `scroll`). */
        val actions: List<String>,
        val enabled: Boolean?,
        /** The developer alias, or null. */
        val tag: String?,
        val inListItem: Boolean,
        /** Bounds in host pixels. */
        val bounds: RectF,
    ) : RegionHit()

    /** The region cannot be read: anchor the host view itself, keeping the region's toolkit. */
    object Unreadable : RegionHit()

    /** Nothing of the region's own is here (or a nested View is): the Views rules continue. */
    object Miss : RegionHit()
}
