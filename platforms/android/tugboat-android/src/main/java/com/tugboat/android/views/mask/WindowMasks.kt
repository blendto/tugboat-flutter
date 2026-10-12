package com.tugboat.android.views.mask

import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.Window
import android.webkit.WebView
import android.widget.ImageView
import android.widget.TextView
import android.widget.VideoView
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.AdapterGuard

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

/**
 * Masks for one capture; [failClosed] when the whole frame is masked.
 * [coverage] says which masking applied, for the host's per-frame report;
 * [structureSignature] is the visible structure the masks were computed
 * from ([StructureHasher], opaque).
 */
internal data class WindowMaskResult(
    val rects: List<MaskRect>,
    val failClosed: Boolean,
    val coverage: MaskCoverage,
    val structureSignature: String,
) {
    companion object {
        fun wholeFrame(reason: MaskCoverageReason) =
            WindowMaskResult(listOf(MaskRect.FULL_FRAME), true, MaskCoverage.wholeFrame(reason), "wholeFrame:${reason.wire}")
    }
}

/**
 * Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
 * Views row). Runs on the main thread inside `capture-runtime`'s mask
 * supplier, immediately before the pixel copy, so the masks describe the
 * frame being copied.
 *
 * - Text: every `TextView`, so `EditText`, buttons, and password fields
 *   (secure text is always masked).
 * - Media: `ImageView`, `VideoView`.
 * - Toolkit regions: a region host (Compose, when `tugboat-compose` is
 *   installed) answers for itself ([MaskWalk]): precise rectangles, its
 *   whole bounds, or the whole frame. Nothing below a host is walked as
 *   Views.
 * - Fail-closed bounds: `WebView`, `SurfaceView`, `TextureView`, and a
 *   Compose host no region reads (`AndroidComposeView`, matched by class
 *   name), over their whole bounds and without looking inside.
 * - Bounds include view transforms and are clipped to the decor view only,
 *   so a partly clipped view is over-masked, never under-masked.
 * - Hidden (not `VISIBLE` or zero alpha) and SDK-owned subtrees are skipped.
 * - **Fail closed**: no attached decor view (`noDecor`), a zero-size decor
 *   view (`noWindowSize`), or any failure while walking (`walkExhausted`)
 *   masks the whole frame. So does motion the layout bounds do not describe
 *   (`animating`, [AnimationProbe]), checked **before** the walk so no
 *   region or View is asked for masks of a frame in motion.
 */
internal object WindowMasks {
    fun compute(window: Window): WindowMaskResult =
        AdapterGuard.run("mask computation", WindowMaskResult.wholeFrame(MaskCoverageReason.WalkExhausted)) {
            val decor = window.peekDecorView()
            if (decor == null || !decor.isAttachedToWindow) {
                WindowMaskResult.wholeFrame(MaskCoverageReason.NoDecor)
            } else {
                compute(decor)
            }
        }

    fun compute(decor: View): WindowMaskResult =
        AdapterGuard.run("mask computation", WindowMaskResult.wholeFrame(MaskCoverageReason.WalkExhausted)) {
            if (decor.width <= 0 || decor.height <= 0) return@run WindowMaskResult.wholeFrame(MaskCoverageReason.NoWindowSize)
            if (AnimationProbe.isAnimating(decor)) return@run WindowMaskResult.wholeFrame(MaskCoverageReason.Animating)
            val walk = MaskWalk(decor)
            walk.collect(decor)
            val wholeFrame = walk.wholeFrameReason
            if (wholeFrame != null) {
                WindowMaskResult.wholeFrame(wholeFrame)
            } else {
                WindowMaskResult(walk.rects, failClosed = false, walk.coverage(), walk.structureSignature())
            }
        }

    /** The reason [view] is masked as a View, or null when it is not. Region hosts are asked first ([MaskWalk]). */
    fun sourceOf(view: View): MaskSource? =
        when (view) {
            is WebView, is SurfaceView, is TextureView -> MaskSource.FailClosed
            is TextView -> MaskSource.Text
            is ImageView, is VideoView -> MaskSource.Media
            else -> if (isComposeContent(view)) MaskSource.FailClosed else null
        }

    /** What a fail-closed View contributes to the coverage report. */
    fun failClosedReason(view: View): MaskCoverageReason? =
        when (view) {
            is WebView -> MaskCoverageReason.WebView
            is SurfaceView, is TextureView -> MaskCoverageReason.SurfaceLayer
            else -> if (isComposeContent(view)) MaskCoverageReason.ComposeDefault else null
        }

    /**
     * The View that draws a Compose UI (`AndroidComposeView`, inside every
     * `ComposeView`), matched by class name so this module needs no Compose
     * dependency. Only reached when no region reads it: its content is not
     * Views, so it is fail-closed.
     */
    fun isComposeContent(view: View): Boolean {
        var type: Class<*>? = view.javaClass
        while (type != null && type != View::class.java) {
            if (type.name == ANDROID_COMPOSE_VIEW) return true
            type = type.superclass
        }
        return false
    }

    private const val ANDROID_COMPOSE_VIEW = "androidx.compose.ui.platform.AndroidComposeView"
}
