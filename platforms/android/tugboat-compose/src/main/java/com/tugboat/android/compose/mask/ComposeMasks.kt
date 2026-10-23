package com.tugboat.android.compose.mask

import android.graphics.RectF
import android.view.View
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.TugboatSensitiveKey
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
 * - sensitive: a `Modifier.tugboatSensitive()` node and every node below it,
 *   each at its own bounds unless they lie inside the sensitive rect above it;
 * - fail-closed: `AndroidView` interop bounds ([InteropViews]);
 * - the whole frame when the semantics tree is unavailable ([root] null).
 *
 * Drawn content without semantics is not masked: the residual leak that
 * opting in accepts, unless it lies inside a sensitive node's bounds.
 * Unplaced subtrees are skipped; bounds are unclipped ([NodeBounds.maskBounds]).
 * Sensitivity is read only here, never by identity ([NodeRules]).
 */
internal object ComposeMasks {
    fun of(host: View, root: SemanticsNode?): RegionMasks {
        if (root == null) return RegionMasks.WholeFrame(MaskCoverageReason.ComposeOwnerUnavailable)
        val rects = ArrayList<RectF>()
        root.children.forEach { collect(it, rects, sensitive = false, cover = null) }
        val interop = InteropViews.bounds(host)
        rects += interop
        return RegionMasks.Rects(rects, if (interop.isEmpty()) emptySet() else setOf(MaskCoverageReason.Interop))
    }

    /**
     * [sensitive] is true below a sensitive node; [cover] is the last
     * sensitive rect added above [node]. Each node adds at most one rect.
     */
    private fun collect(node: SemanticsNode, out: MutableList<RectF>, sensitive: Boolean, cover: RectF?) {
        if (!node.layoutInfo.isPlaced) return
        val marked = sensitive || node.config.getOrNull(TugboatSensitiveKey) == true
        val maskable = NodeRules.isMaskable(node)
        val bounds = if (maskable || marked) NodeBounds.maskBounds(node) else null
        val newCover = marked && bounds != null && cover?.contains(bounds) != true
        if (bounds != null && (maskable || newCover)) out += bounds
        val childCover = if (newCover) bounds else cover
        node.children.forEach { collect(it, out, marked, childCover) }
    }
}
