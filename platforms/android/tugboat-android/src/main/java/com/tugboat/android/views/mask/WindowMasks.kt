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

/** Why a view is masked (native SDK note 2.1). */
internal enum class MaskSource {
    Text,
    Media,

    /** Content the SDK cannot see into: masked over its whole bounds and never walked. */
    FailClosed,
}

/** Why a capture masks the whole frame. */
internal enum class FailClosedReason {
    /** No attached or sized decor view, or the walk failed. */
    TreeUnreadable,

    /** A legacy view animation or a layout transition is running ([AnimationProbe]). */
    Animating,
}

/**
 * Masks for one capture; [failClosed] when the whole frame is masked, for
 * [reason].
 */
internal data class WindowMaskResult(
    val rects: List<MaskRect>,
    val failClosed: Boolean,
    val reason: FailClosedReason? = null,
)

/**
 * Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
 * Views row). Runs on the main thread when the host handles
 * `capture.request`, just before the pixel copy.
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
 * - **Fail closed**: no attached decor view, a zero-size decor view, or any
 *   failure while walking masks the whole frame. So does motion the layout
 *   bounds do not describe: a running legacy `Animation` or
 *   `LayoutTransition` on a visible view ([AnimationProbe]).
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
            if (AnimationProbe.isAnimating(decor)) return@run failClosed(FailClosedReason.Animating)
            val rects = ArrayList<MaskRect>()
            collect(decor, decor, rects)
            WindowMaskResult(rects, failClosed = false)
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

    private fun collect(decor: View, view: View, out: MutableList<MaskRect>) {
        if (isHidden(view)) return
        val source = sourceOf(view)
        if (source != null) {
            ViewGeometry.boundsIn(decor, view)?.let { normalize(it, decor) }?.let(out::add)
            if (source == MaskSource.FailClosed) return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collect(decor, view.getChildAt(i), out)
        }
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

    private fun failClosed(reason: FailClosedReason = FailClosedReason.TreeUnreadable) =
        WindowMaskResult(listOf(MaskRect.FULL_FRAME), failClosed = true, reason = reason)
}
