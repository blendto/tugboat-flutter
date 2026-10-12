package com.tugboat.android.toolkit

import android.app.Activity
import android.view.View

/**
 * A toolkit whose content lives inside one View (a *region host*, such as
 * Compose's `AndroidComposeView`) that the Views adapter cannot read as
 * Views. The Views adapter consults registered regions before its own rules,
 * and before treating such a host as fail-closed.
 *
 * Coordinates and rectangles are physical pixels in the host's own
 * coordinate space. Every method runs on the main thread. The Views adapter
 * guards every call: a throw counts as "cannot read" (no target, no
 * scrollables, a whole-frame mask). Implementations keep no listeners of
 * their own, so they are inert once the adapter stops calling them.
 */
@TugboatToolkitApi
interface ToolkitRegion {
    /** The anchor `toolkit` for everything inside this region (the engine's closed set). */
    val toolkit: String

    /** The canonical-path token of the host view itself, for example `Compose`. */
    val hostToken: String

    /** True when [view] is a host of this region. Cheap: it is asked for many views. */
    fun hosts(view: View): Boolean

    /** The tap target at ([x], [y]) in [host]. */
    fun targetAt(host: View, x: Float, y: Float): RegionHit

    /** The scrollables currently inside [host]; empty when unreadable. */
    fun scrollables(host: View): List<RegionScrollable>

    /** Mask rectangles for [host] under `allTextAndMedia`. */
    fun masks(host: View): RegionMasks

    /** What has input focus inside [host], or null when unreadable. */
    fun focus(host: View): RegionFocus?

    /** A route key for [host] that overrides its Views route, or null to keep that. */
    fun routeKey(host: View): String?

    /** The `trackNavigation` hook: [activity]'s navigation destination is now [route]. */
    fun onDestinationChanged(activity: Activity, route: String?)
}

/** What has focus inside a region host (the engine's `focus.kind`, minus `none`). */
@TugboatToolkitApi
enum class RegionFocus {
    TextInput,
    Other,
}
