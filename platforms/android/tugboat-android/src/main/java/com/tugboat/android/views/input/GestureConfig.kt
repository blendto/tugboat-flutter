package com.tugboat.android.views.input

import android.content.Context
import android.view.ViewConfiguration
import org.json.JSONObject

/**
 * Gesture thresholds in **logical pixels (dp)**, the unit of every
 * coordinate the adapter sends (`x`, `y`, scroll offsets): physical pixels
 * divided by `DisplayMetrics.density`. The engine compares positions it
 * receives against its `gesture` config, so the host must configure the
 * engine with [toEngineJson] of the same instance the adapter uses for its
 * local tap-evidence check; then both agree on what is a tap.
 *
 * Values come from `ViewConfiguration` (stateful-engine.md section 6:
 * "Android uses ViewConfiguration"): `touchSlop` is the scaled touch slop,
 * `panSlop` the paging touch slop (2x), `scaleSlop` the span slop
 * `ScaleGestureDetector` uses (2x touch slop). Android has no trackpad
 * scale threshold; Flutter's 1.08 is kept.
 */
internal data class GestureConfig(
    val touchSlop: Double,
    val panSlop: Double,
    val scaleSlop: Double,
    val trackpadScaleThreshold: Double = DEFAULT_TRACKPAD_SCALE_THRESHOLD,
) {
    /** The engine's `engine.configure.gesture` group. */
    fun toEngineJson(): JSONObject =
        JSONObject()
            .put("touchSlop", touchSlop)
            .put("panSlop", panSlop)
            .put("scaleSlop", scaleSlop)
            .put("trackpadScaleThreshold", trackpadScaleThreshold)

    companion object {
        const val DEFAULT_TRACKPAD_SCALE_THRESHOLD = 1.08

        fun from(context: Context): GestureConfig {
            val config = ViewConfiguration.get(context)
            val density = context.resources.displayMetrics.density.toDouble().takeIf { it > 0 } ?: 1.0
            val touchSlop = config.scaledTouchSlop / density
            return GestureConfig(
                touchSlop = touchSlop,
                panSlop = config.scaledPagingTouchSlop / density,
                scaleSlop = touchSlop * 2,
            )
        }
    }
}
