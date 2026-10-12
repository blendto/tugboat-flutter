package com.tugboat.android.views.mask

import android.graphics.RectF
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.webkit.WebView
import android.widget.ImageView
import android.widget.TextView
import android.widget.VideoView
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.identity.ViewTags

/**
 * One mask rectangle normalized to the window's decor view, the rule
 * `capture-runtime`'s `capture(Window, …)` applies to
 * `com.tugboat.capture.NormalizedMask` (x, y, width, height in [0, 1]).
 */
internal data class MaskRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    companion object {
        val FULL_FRAME = MaskRect(0.0, 0.0, 1.0, 1.0)
    }
}

/** Masks for one capture; [failClosed] when the whole frame is masked because the tree could not be read. */
internal data class WindowMaskResult(val rects: List<MaskRect>, val failClosed: Boolean)

/**
 * Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
 * Views row). Runs on the main thread when the host handles
 * `capture.request`, just before the pixel copy.
 *
 * - Text: every `TextView`, so `EditText`, buttons, and password fields
 *   (secure text is always masked).
 * - Media: `ImageView`, `VideoView`.
 * - Fail-closed bounds: `WebView`, `SurfaceView`, `TextureView`, over their
 *   whole bounds and without looking inside.
 * - Bounds include view transforms and are clipped to the decor view only,
 *   so a partly clipped view is over-masked, never under-masked.
 * - Hidden (not `VISIBLE` or zero alpha) and SDK-owned subtrees are skipped.
 * - **Fail closed**: no attached decor view, a zero-size decor view, or any
 *   failure while walking masks the whole frame.
 */
internal object WindowMasks {
    fun compute(window: Window): WindowMaskResult =
        AdapterGuard.run("mask computation", failClosed()) {
            val decor = window.peekDecorView()
            if (decor == null || !decor.isAttachedToWindow) failClosed() else compute(decor)
        }

    fun compute(decor: View): WindowMaskResult =
        AdapterGuard.run("mask computation", failClosed()) {
            if (decor.width <= 0 || decor.height <= 0) return@run failClosed()
            val rects = ArrayList<MaskRect>()
            collect(decor, decor, rects)
            WindowMaskResult(rects, failClosed = false)
        }

    private fun collect(decor: View, view: View, out: MutableList<MaskRect>) {
        if (isHidden(view)) return
        if (isMasked(view)) {
            ViewGeometry.boundsIn(decor, view)?.let { normalize(it, decor) }?.let(out::add)
            if (isOpaque(view)) return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collect(decor, view.getChildAt(i), out)
        }
    }

    private fun isHidden(view: View): Boolean =
        view.visibility != View.VISIBLE || view.alpha == 0f || ViewTags.isSdkOwned(view)

    private fun isMasked(view: View): Boolean =
        view is TextView || view is ImageView || view is VideoView || isOpaque(view)

    /** Content the SDK cannot see into: masked whole, never walked. */
    private fun isOpaque(view: View): Boolean = view is WebView || view is SurfaceView || view is TextureView

    private fun normalize(bounds: RectF, decor: View): MaskRect? {
        val width = decor.width.toDouble()
        val height = decor.height.toDouble()
        val left = (bounds.left / width).coerceIn(0.0, 1.0)
        val top = (bounds.top / height).coerceIn(0.0, 1.0)
        val right = (bounds.right / width).coerceIn(0.0, 1.0)
        val bottom = (bounds.bottom / height).coerceIn(0.0, 1.0)
        if (right <= left || bottom <= top) return null
        return MaskRect(left, top, right - left, bottom - top)
    }

    private fun failClosed() = WindowMaskResult(listOf(MaskRect.FULL_FRAME), failClosed = true)
}
