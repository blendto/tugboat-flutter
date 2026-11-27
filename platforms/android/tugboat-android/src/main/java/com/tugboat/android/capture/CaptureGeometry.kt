package com.tugboat.android.capture

import android.view.View
import kotlin.math.ceil

/**
 * The size of a window's decor view, which is both the capture boundary
 * and the space mask rectangles and pointer facts are measured in.
 */
internal data class CaptureGeometry(val widthPx: Int, val heightPx: Int, val density: Float) {
    /** The boundary in logical pixels (dp), at the decor view's origin. */
    val boundaryRect: BoundaryRect
        get() = BoundaryRect(0.0, 0.0, widthPx / dp, heightPx / dp)

    private val dp: Double
        get() = density.toDouble().takeIf { it > 0 } ?: 1.0

    /**
     * Encoded frame size: [CAPTURE_PIXEL_RATIO] JPEG pixels per dp (Flutter's
     * `capturePixelRatio` default) times the engine's [scale], never above
     * the window's own pixels and at least one pixel.
     */
    fun pixelSize(scale: Double): Pair<Int, Int> {
        val ratio = CAPTURE_PIXEL_RATIO * scale.coerceIn(MIN_SCALE, 1.0)
        return scaled(widthPx, ratio) to scaled(heightPx, ratio)
    }

    /** Rounds up, ignoring float noise (1080 x 0.6 is 648, not 649). */
    private fun scaled(px: Int, ratio: Double): Int = ceil(px / dp * ratio - EPSILON).toInt().coerceIn(1, px)

    companion object {
        /** Flutter `TugboatReplayConfig.capturePixelRatio` default. */
        const val CAPTURE_PIXEL_RATIO = 0.75
        private const val MIN_SCALE = 0.1
        private const val EPSILON = 1e-6

        /** Null when [decor] is missing or not laid out. */
        fun of(decor: View?): CaptureGeometry? {
            if (decor == null || decor.width <= 0 || decor.height <= 0) return null
            return CaptureGeometry(decor.width, decor.height, decor.resources.displayMetrics.density)
        }
    }
}
