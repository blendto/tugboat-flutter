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
 * Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
 * Views row). Runs on the main thread inside `capture-runtime`'s mask
 * supplier, immediately before the pixel copy, so the masks describe the
 * frame being copied.
 *
 * - Text: every `TextView`, so `EditText`, buttons, and password fields
 *   (secure text is always masked).
 * - Media: `ImageView`, `VideoView`.
 * - Fail-closed bounds: `WebView`, `SurfaceView`, `TextureView`, and
 *   Compose hosts (`ComposeView`), over their whole bounds and without
 *   looking inside.
 * - Bounds include view transforms and are clipped to the decor view only,
 *   so a partly clipped view is over-masked, never under-masked.
 * - Hidden (not `VISIBLE` or zero alpha) and SDK-owned subtrees are skipped.
 * - **Fail closed**: no attached decor view (`noDecor`), a zero-size decor
 *   view (`noWindowSize`), or any failure while walking (`walkExhausted`)
 *   masks the whole frame. So does motion the layout bounds do not describe:
 *   a running legacy `Animation` or `LayoutTransition` on a visible view
 *   (`animating`, [AnimationProbe]).
 * - The same walk reports the [MaskCoverage] (a Compose host makes it
 *   `wholeHost`; `WebView` and surface layers are noted) and hashes the
 *   visible structure ([StructureHasher]).
 */
internal object WindowMasks {
    fun compute(window: Window): WindowMaskResult =
        AdapterGuard.run("mask computation", WindowMaskResult.wholeFrame(MaskReason.WalkExhausted)) {
            val decor = window.peekDecorView()
            if (decor == null || !decor.isAttachedToWindow) WindowMaskResult.wholeFrame(MaskReason.NoDecor) else compute(decor)
        }

    fun compute(decor: View): WindowMaskResult =
        AdapterGuard.run("mask computation", WindowMaskResult.wholeFrame(MaskReason.WalkExhausted)) {
            if (decor.width <= 0 || decor.height <= 0) return@run WindowMaskResult.wholeFrame(MaskReason.NoWindowSize)
            if (AnimationProbe.isAnimating(decor)) return@run WindowMaskResult.wholeFrame(MaskReason.Animating)
            val walk = Walk(decor)
            walk.collect(decor)
            walk.result()
        }

    /** The reason [view] is masked, or null when it is not. */
    fun sourceOf(view: View): MaskSource? =
        when (view) {
            is WebView, is SurfaceView, is TextureView -> MaskSource.FailClosed
            is TextView -> MaskSource.Text
            is ImageView, is VideoView -> MaskSource.Media
            else -> if (isComposeHost(view)) MaskSource.FailClosed else null
        }

    /**
     * A Compose UI hosted in Views (`ComposeView`, `AndroidComposeView`),
     * matched by class name so this module needs no Compose dependency. Its
     * content is not Views, so it is fail-closed until the Compose adapter
     * supplies its masks.
     */
    private fun isComposeHost(view: View): Boolean {
        var type: Class<*>? = view.javaClass
        while (type != null && type != View::class.java) {
            if (type.name in COMPOSE_HOSTS) return true
            type = type.superclass
        }
        return false
    }

    private val COMPOSE_HOSTS = setOf(
        "androidx.compose.ui.platform.AbstractComposeView",
        "androidx.compose.ui.platform.AndroidComposeView",
    )

    /** One walk of a laid-out decor view: rectangles, coverage reasons, structure. */
    private class Walk(private val decor: View) {
        private val rects = ArrayList<MaskRect>()
        private val reasons = LinkedHashSet<MaskReason>()
        private val structure = StructureHasher(decor.width, decor.height)

        fun collect(view: View) {
            structure.addView(view)
            if (isHidden(view)) return
            val source = sourceOf(view)
            if (source != null) {
                ViewGeometry.boundsIn(decor, view)?.let { normalize(it, decor) }?.let(::addMask)
                if (source == MaskSource.FailClosed) {
                    failClosedReason(view)?.let(reasons::add)
                    return
                }
            }
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) collect(view.getChildAt(i))
            }
        }

        fun result(): WindowMaskResult {
            val mode = if (MaskReason.ComposeDefault in reasons) MaskMode.WholeHost else MaskMode.Precise
            return WindowMaskResult(rects, MaskCoverage(mode, reasons.toList()), structure.value())
        }

        private fun addMask(rect: MaskRect) {
            rects += rect
            structure.addMask(rect)
        }
    }

    private fun failClosedReason(view: View): MaskReason? =
        when (view) {
            is WebView -> MaskReason.WebView
            is SurfaceView, is TextureView -> MaskReason.SurfaceLayer
            else -> if (isComposeHost(view)) MaskReason.ComposeDefault else null
        }

    private fun isHidden(view: View): Boolean =
        view.visibility != View.VISIBLE || view.alpha == 0f || ViewTags.isSdkOwned(view)

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
}
