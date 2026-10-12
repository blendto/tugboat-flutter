package com.tugboat.android.compose.scroll

import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.identity.NodeTargets
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.RegionScrollable

/**
 * The scrollables of a Compose host: merged-tree nodes with a
 * `ScrollAxisRange` (vertical first), keyed by semantics id, sampled when
 * the Views adapter diffs them per frame (native SDK note 5).
 *
 * Offsets are the range's `value`: pixels for `Modifier.verticalScroll` /
 * `horizontalScroll`, but Compose's own estimate for lazy layouts (500 per
 * item plus the first item's pixel offset). Lazy offsets are therefore
 * approximate and lazy extents (a placeholder `value + 100`) are not sent.
 */
internal object ComposeScrollables {
    fun of(root: SemanticsNode?): List<RegionScrollable> {
        if (root == null) return emptyList()
        val out = ArrayList<RegionScrollable>()
        root.children.forEach { collect(root, it, out) }
        return out
    }

    private fun collect(root: SemanticsNode, node: SemanticsNode, out: MutableList<RegionScrollable>) {
        if (NodeRules.isExcluded(node)) return
        scrollable(root, node)?.let(out::add)
        node.children.forEach { collect(root, it, out) }
    }

    private fun scrollable(root: SemanticsNode, node: SemanticsNode): RegionScrollable? {
        val vertical = node.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
        val range = vertical ?: node.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) ?: return null
        return RegionScrollable(
            key = node.id,
            vertical = vertical != null,
            offsetPx = range.value(),
            maxExtentPx = if (isLazy(node)) null else range.maxValue(),
            target = { NodeTargets.of(root, node) },
        )
    }

    private fun isLazy(node: SemanticsNode): Boolean =
        SemanticsProperties.CollectionInfo in node.config || SemanticsProperties.IndexForKey in node.config
}
