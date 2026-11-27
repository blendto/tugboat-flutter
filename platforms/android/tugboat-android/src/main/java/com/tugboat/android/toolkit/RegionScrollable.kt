package com.tugboat.android.toolkit

/**
 * One scrollable inside a region host, resolved once when a gesture starts
 * and then read every frame. [key] is stable for the scrollable's lifetime
 * within its host. The readers return physical pixels from live state; a
 * null extent means it is unknown.
 */
@TugboatToolkitApi
class RegionScrollable(
    val key: Int,
    val vertical: Boolean,
    val offsetPx: () -> Float,
    val maxExtentPx: () -> Float?,
    /** The scrollable's own target, for the `start` fact's anchor; resolved only when a scroll starts. */
    val target: () -> RegionHit.Target?,
)
