package com.tugboat.android.compose.mask

import android.graphics.RectF
import android.view.View
import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionMasks

/**
 * `ComposeMasking.SemanticsBestEffort` masks (native SDK note 2.1, Compose
 * row), from the **unmerged** semantics tree so each text and image is
 * masked at its own bounds:
 *
 * - text: nodes with `Text` or `EditableText` (password fields included);
 * - media: `Role.Image` and image-like nodes with a `ContentDescription`;
 * - fail-closed: `AndroidView` interop bounds ([InteropViews]);
 * - the whole frame when the semantics tree is unavailable ([root] null).
 *
 * Drawn content without semantics is not masked: the residual leak that
 * opting in accepts. Unplaced subtrees are skipped; bounds are unclipped
 * ([NodeBounds.maskBounds]).
 */
internal object ComposeMasks {
    fun of(host: View, root: SemanticsNode?): RegionMasks {
        if (root == null) return RegionMasks.WholeFrame(MaskCoverageReason.ComposeOwnerUnavailable)
        val rects = ArrayList<RectF>()
        root.children.forEach { collect(it, rects) }
        val interop = InteropViews.bounds(host)
        rects += interop
        return RegionMasks.Rects(rects, if (interop.isEmpty()) emptySet() else setOf(MaskCoverageReason.Interop))
    }

    private fun collect(node: SemanticsNode, out: MutableList<RectF>) {
        if (!node.layoutInfo.isPlaced) return
        if (NodeRules.isMaskable(node)) out += NodeBounds.maskBounds(node)
        node.children.forEach { collect(it, out) }
    }
}
