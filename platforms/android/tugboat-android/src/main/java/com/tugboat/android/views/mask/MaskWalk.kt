package com.tugboat.android.views.mask

import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.identity.ViewTags
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions

/**
 * One walk of a decor view for [WindowMasks]. Each view is classified once:
 * a region host answers for itself and is not walked; otherwise its View
 * mask source applies. Rectangles are normalized to the decor view. The same
 * walk hashes the visible structure ([StructureHasher]).
 */
internal class MaskWalk(private val decor: View) {
    val rects = ArrayList<MaskRect>()
    private val reasons = HashSet<MaskCoverageReason>()
    private val structure = StructureHasher(decor.width, decor.height)
    private var wholeHost = false

    /** Set when the walk met a region host; [structureSignature] does not see inside one. */
    var metRegionHost = false
        private set

    /** Set when a region asked for the whole frame; the walk stops there. */
    var wholeFrameReason: MaskCoverageReason? = null
        private set

    fun collect(view: View) {
        if (wholeFrameReason != null) return
        structure.addView(view)
        if (isHidden(view)) return
        val region = Regions.regionOf(view)
        if (region != null) return region(RegionHost(view, region))
        val source = WindowMasks.sourceOf(view)
        if (source != null) {
            ViewGeometry.boundsIn(decor, view)?.let(::add)
            if (source == MaskSource.FailClosed) return failClosed(view)
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collect(view.getChildAt(i))
        }
    }

    fun coverage(): MaskCoverage = MaskCoverage(if (wholeHost) MaskMode.WholeHost else MaskMode.Precise, reasons)

    fun structureSignature(): String = structure.value()

    private fun region(host: RegionHost) {
        metRegionHost = true
        when (val masks = host.masks()) {
            is RegionMasks.WholeFrame -> wholeFrameReason = masks.reason
            is RegionMasks.WholeHost -> {
                wholeHost = true
                reasons += masks.reason
                ViewGeometry.boundsIn(decor, host.view)?.let(::add)
            }
            is RegionMasks.Rects -> {
                reasons += masks.reasons
                for (rect in masks.rects) ViewGeometry.mapRect(decor, host.view, rect)?.let(::add)
            }
        }
    }

    /** A Compose host no region reads is masked whole, like a region's default. */
    private fun failClosed(view: View) {
        val reason = WindowMasks.failClosedReason(view) ?: return
        reasons += reason
        if (reason == MaskCoverageReason.ComposeDefault) wholeHost = true
    }

    private fun isHidden(view: View): Boolean =
        view.visibility != View.VISIBLE || view.alpha == 0f || ViewTags.isSdkOwned(view)

    private fun add(bounds: RectF) {
        val width = decor.width.toDouble()
        val height = decor.height.toDouble()
        val left = (bounds.left / width).coerceIn(0.0, 1.0)
        val top = (bounds.top / height).coerceIn(0.0, 1.0)
        val right = (bounds.right / width).coerceIn(0.0, 1.0)
        val bottom = (bounds.bottom / height).coerceIn(0.0, 1.0)
        if (right <= left || bottom <= top) return
        val rect = MaskRect(left, top, right - left, bottom - top)
        rects += rect
        structure.addMask(rect)
    }
}
