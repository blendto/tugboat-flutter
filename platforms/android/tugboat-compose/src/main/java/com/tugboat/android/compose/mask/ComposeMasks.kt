package com.tugboat.android.compose.mask

import android.graphics.RectF
import android.view.View
import androidx.compose.ui.layout.LayoutInfo
import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.SensitiveMarkers
import com.tugboat.android.compose.TugboatSensitiveElement
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.SensitiveRects
import java.util.IdentityHashMap

/**
 * `ComposeMasking.SemanticsBestEffort` masks (native SDK note 2.1, Compose
 * row), from the **unmerged** semantics tree so each text and image is
 * masked at its own bounds:
 *
 * - text: nodes with `Text` or `EditableText` (password fields included);
 * - media: `Role.Image` and image-like nodes with a `ContentDescription`;
 * - sensitive: each placed `Modifier.tugboatSensitive()` element's unclipped
 *   bounds (registered by the element, so it needs no semantics), and every
 *   semantics node laid out inside one, at its own bounds unless they lie
 *   inside the sensitive rect above it ([SensitiveRects]);
 * - fail-closed: `AndroidView` interop bounds ([InteropViews]);
 * - the whole frame when the semantics tree is unavailable ([root] null).
 *
 * Drawn content without semantics is not masked: the residual leak that
 * opting in accepts, unless it lies inside a sensitive element's bounds.
 * Unplaced subtrees are skipped; bounds are unclipped ([NodeBounds.maskBounds]).
 */
internal object ComposeMasks {
    fun of(host: View, root: SemanticsNode?): RegionMasks {
        if (root == null) return RegionMasks.WholeFrame(MaskCoverageReason.ComposeOwnerUnavailable)
        val rects = ArrayList<RectF>()
        val markers = SensitiveMarkers.placed(host)
        markers.forEach { rects += NodeBounds.unclipped(it) }
        val marks = if (markers.isEmpty()) null else MarkedAncestors()
        root.children.forEach { collect(it, rects, marks, sensitive = false, cover = null) }
        val interop = InteropViews.bounds(host)
        rects += interop
        return RegionMasks.Rects(rects, if (interop.isEmpty()) emptySet() else setOf(MaskCoverageReason.Interop))
    }

    /** [marks] is null when the host has no sensitive element, so unmarked screens pay nothing. */
    private fun collect(node: SemanticsNode, out: MutableList<RectF>, marks: MarkedAncestors?, sensitive: Boolean, cover: RectF?) {
        if (!node.layoutInfo.isPlaced) return
        val ownCover = if (sensitive || marks == null) null else marks.boundsAbove(node.layoutInfo)
        val marked = sensitive || ownCover != null
        val maskable = NodeRules.isMaskable(node)
        val bounds = if (maskable || marked) NodeBounds.maskBounds(node) else null
        val step = SensitiveRects.step(marked, maskable, bounds, cover ?: ownCover)
        if (step.addsRect && bounds != null) out += bounds
        node.children.forEach { collect(it, out, marks, marked, step.childCover) }
    }

    /**
     * The bounds of the nearest sensitive element on a layout node or its
     * layout ancestors, found in their modifier chains. One lookup per layout
     * node per mask pass.
     */
    private class MarkedAncestors {
        private val memo = IdentityHashMap<LayoutInfo, RectF?>()

        fun boundsAbove(start: LayoutInfo): RectF? {
            val chain = ArrayList<LayoutInfo>()
            var current: LayoutInfo? = start
            var found: RectF? = null
            while (current != null) {
                if (memo.containsKey(current)) {
                    found = memo[current]
                    break
                }
                chain += current
                found = ownBounds(current)
                if (found != null) break
                current = current.parentInfo
            }
            chain.forEach { memo[it] = found }
            return found
        }

        private fun ownBounds(layout: LayoutInfo): RectF? {
            if (!layout.isAttached) return null
            val info = layout.getModifierInfo().firstOrNull { it.modifier === TugboatSensitiveElement } ?: return null
            return info.coordinates.takeIf { it.isAttached }?.let(NodeBounds::unclipped)
        }
    }
}
