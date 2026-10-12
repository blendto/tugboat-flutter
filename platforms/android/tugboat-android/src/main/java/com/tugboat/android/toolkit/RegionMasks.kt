package com.tugboat.android.toolkit

import android.graphics.RectF

/**
 * Masks for one region host: [rects] in host pixels, or [wholeFrame] when
 * the region cannot be read and the whole captured frame must be masked.
 */
@TugboatToolkitApi
class RegionMasks(val rects: List<RectF>, val wholeFrame: Boolean) {
    companion object {
        val WHOLE_FRAME = RegionMasks(emptyList(), wholeFrame = true)
    }
}
