package com.tugboat.android.toolkit

/**
 * One scrollable inside a region host, sampled now. [key] is stable for the
 * scrollable's lifetime within its host. Offsets are physical pixels; a null
 * [maxExtentPx] means the extent is unknown.
 */
@TugboatToolkitApi
class RegionScrollable(
    val key: Int,
    val vertical: Boolean,
    val offsetPx: Float,
    val maxExtentPx: Float?,
    /** The scrollable's own target, for the `start` fact's anchor. */
    val target: RegionHit.Target?,
)
