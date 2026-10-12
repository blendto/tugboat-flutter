package com.tugboat.android.compose.scroll

import androidx.compose.ui.semantics.ScrollAxisRange
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.identity.NodeTargets
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.RegionScrollable

/**
 * The scrollables under a touch in a Compose host: merged-tree nodes with a
 * `ScrollAxisRange` (vertical first) whose bounds hold the point, outermost
 * first, keyed by semantics id. Resolved once per gesture; the range's
 * `value` / `maxValue` read live scroll state, so the Views adapter samples
 * them per frame without walking the tree (native SDK note 5).
 *
 * Offsets are the range's `value`: pixels for `Modifier.verticalScroll` /
 * `horizontalScroll`, but Compose's own estimate for lazy layouts (500 per
 * item plus the first item's pixel offset). Lazy offsets are therefore
 * approximate, and lazy extents (a placeholder `value + 100`) are not sent.
 */
internal object ComposeScrollables {
    fun at(root: SemanticsNode?, x: Float, y: Float): List<RegionScrollable> {
        if (root == null) return emptyList()
        val out = ArrayList<RegionScrollable>()
        root.children.forEach { collect(root, it, x, y, out) }
        return out
    }

    private fun collect(root: SemanticsNode, node: SemanticsNode, x: Float, y: Float, out: MutableList<RegionScrollable>) {
        if (NodeRules.isExcluded(node) || !NodeBounds.touches(node, x, y)) return
        scrollable(root, node)?.let(out::add)
        node.children.forEach { collect(root, it, x, y, out) }
    }

    private fun scrollable(root: SemanticsNode, node: SemanticsNode): RegionScrollable? {
        val vertical = node.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
        val range: ScrollAxisRange = vertical ?: node.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) ?: return null
        val lazy = SemanticsProperties.CollectionInfo in node.config || SemanticsProperties.IndexForKey in node.config
        return RegionScrollable(
            key = node.id,
            vertical = vertical != null,
            offsetPx = { range.value() },
            maxExtentPx = { if (lazy) null else range.maxValue() },
            target = { NodeTargets.of(root, node) },
        )
    }
}
