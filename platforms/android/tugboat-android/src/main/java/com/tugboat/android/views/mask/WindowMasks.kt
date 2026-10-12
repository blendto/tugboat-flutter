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
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions

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
 * - Toolkit regions: a region host (Compose, when `tugboat-compose` is
 *   installed) supplies its own rectangles, and may ask for the whole frame
 *   (it cannot read itself); nothing below a host is walked as Views.
 * - Fail-closed bounds: `WebView`, `SurfaceView`, `TextureView`, and
 *   Compose hosts that no region reads (`ComposeView`), over their whole
 *   bounds and without looking inside.
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
            val masks = Collected(decor)
            masks.collect(decor)
            if (masks.wholeFrame) failClosed() else WindowMaskResult(masks.rects, failClosed = false)
        }

    /** The reason [view] is masked as a View, or null when it is not (a region host masks itself). */
    fun sourceOf(view: View): MaskSource? =
        when (view) {
            is WebView, is SurfaceView, is TextureView -> MaskSource.FailClosed
            is TextView -> MaskSource.Text
            is ImageView, is VideoView -> MaskSource.Media
            else -> if (isUnreadComposeHost(view)) MaskSource.FailClosed else null
        }

    /**
     * A Compose UI hosted in Views (`ComposeView`, `AndroidComposeView`),
     * matched by class name so this module needs no Compose dependency, that
     * no toolkit region reads: neither the view nor a direct child of it
     * (`ComposeView` wraps the `AndroidComposeView` a region hosts) is a
     * region host. Its content is not Views, so it is fail-closed.
     */
    private fun isUnreadComposeHost(view: View): Boolean {
        if (!isComposeHost(view) || Regions.hostOf(view) != null) return false
        val group = view as? ViewGroup ?: return true
        return (0 until group.childCount).none { Regions.hostOf(group.getChildAt(it)) != null }
    }

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

    /** One walk's rectangles; [wholeFrame] once a region host asked for the whole frame. */
    private class Collected(private val decor: View) {
        val rects = ArrayList<MaskRect>()
        var wholeFrame = false

        fun collect(view: View) {
            if (wholeFrame || isHidden(view)) return
            val host = Regions.hostOf(view)
            if (host != null) return region(host)
            val source = sourceOf(view)
            if (source != null) {
                ViewGeometry.boundsIn(decor, view)?.let(::add)
                if (source == MaskSource.FailClosed) return
            }
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) collect(view.getChildAt(i))
            }
        }

        private fun region(host: RegionHost) {
            val masks = host.masks()
            if (masks.wholeFrame) {
                wholeFrame = true
                return
            }
            for (rect in masks.rects) ViewGeometry.mapRect(decor, host.view, rect)?.let(::add)
        }

        private fun add(bounds: RectF) {
            normalize(bounds, decor)?.let(rects::add)
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

    private fun failClosed() = WindowMaskResult(listOf(MaskRect.FULL_FRAME), failClosed = true)
}
