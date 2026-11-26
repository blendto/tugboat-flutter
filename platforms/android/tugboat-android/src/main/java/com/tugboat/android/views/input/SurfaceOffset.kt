package com.tugboat.android.views.input

import android.view.View

/**
 * Where a window's origin sits in the adapter's surface space (the
 * activity's decor view, origin 0,0), in physical pixels. A dialog window's
 * `MotionEvent` x/y are in the dialog's own window; adding this offset
 * puts them in the activity's space, which is what `input.pointer` reports.
 * Zero for the activity's own window.
 */
internal data class SurfaceOffset(val xPx: Float, val yPx: Float) {
    companion object {
        val ZERO = SurfaceOffset(0f, 0f)

        /**
         * The offset of a window whose decor is at ([windowX], [windowY]) on
         * screen from a surface whose decor is at ([surfaceX], [surfaceY]).
         * `View.getLocationOnScreen` already includes the window's position
         * (gravity, `LayoutParams.x/y`, insets, multi-window bounds), so no
         * gravity math is needed.
         */
        fun between(windowX: Int, windowY: Int, surfaceX: Int, surfaceY: Int): SurfaceOffset =
            SurfaceOffset((windowX - surfaceX).toFloat(), (windowY - surfaceY).toFloat())

        /**
         * Reads both decors' on-screen locations through [locate]
         * (`View::getLocationOnScreen`, a seam for tests); [ZERO] when the
         * surface is gone or either view is not attached.
         */
        fun of(window: View, surface: View?, locate: (View, IntArray) -> Unit): SurfaceOffset {
            if (surface == null || !window.isAttachedToWindow || !surface.isAttachedToWindow) return ZERO
            val windowXY = IntArray(2)
            val surfaceXY = IntArray(2)
            locate(window, windowXY)
            locate(surface, surfaceXY)
            return between(windowXY[0], windowXY[1], surfaceXY[0], surfaceXY[1])
        }
    }
}
