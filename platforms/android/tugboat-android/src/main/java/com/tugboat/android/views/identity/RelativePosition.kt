package com.tugboat.android.views.identity

import android.graphics.RectF
import android.view.View

/** The anchor `relativePosition`: where a target's center sits in its window, with Flutter's thresholds. */
internal object RelativePosition {
    private const val TOP_LIMIT = 0.33f
    private const val BOTTOM_LIMIT = 0.66f

    /** `top`, `center`, or `bottom` for [bounds] in [window]'s coordinates; null when unknown. */
    fun of(window: View, bounds: RectF?): String? {
        if (bounds == null || window.height <= 0) return null
        val centerY = bounds.centerY() / window.height
        return when {
            centerY < TOP_LIMIT -> "top"
            centerY > BOTTOM_LIMIT -> "bottom"
            else -> "center"
        }
    }
}
