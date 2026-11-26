package com.tugboat.android.compose.inventory

import android.graphics.RectF
import android.view.View
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.identity.NodePath
import com.tugboat.android.compose.identity.NodePaths
import com.tugboat.android.compose.identity.NodeTargets
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.InventoryTier
import com.tugboat.android.toolkit.RegionInventory
import com.tugboat.android.toolkit.RegionInventoryEntry

/**
 * Scene inventory entries from a Compose host's merged semantics tree, with
 * the tap targets' paths ([NodePaths.index], one walk):
 *
 * - **Interactive**: actionable nodes.
 * - **Content**: `Role.Image` nodes, and text or image-like nodes covering at
 *   least 2% of the **window** (as Views and Flutter measure it). Presence
 *   only: no text is read.
 * - Rows without a stable index (`[item]`) share one path; only the first is
 *   listed.
 *
 * The first `limit` entries are built; later ones are only counted.
 */
internal object ComposeInventory {
    private const val LARGE_TEXT_AREA = 0.02
    private const val LAZY_ITEM = "[item]"

    fun of(host: View, root: SemanticsNode?, limit: Int): RegionInventory {
        if (root == null || host.width <= 0 || host.height <= 0) return RegionInventory.EMPTY
        val window = host.rootView
        val windowArea = window.width.toDouble() * window.height.toDouble()
        if (!(windowArea > 0)) return RegionInventory.EMPTY
        val walk = Walk(host, NodePaths.index(root), windowArea, limit)
        walk.visit(root)
        return RegionInventory(walk.entries, walk.total)
    }

    private class Walk(
        private val host: View,
        private val paths: Map<Int, NodePath>,
        private val windowArea: Double,
        private val limit: Int,
    ) {
        val entries = ArrayList<RegionInventoryEntry>()
        var total = 0
            private set
        private val seenLazyItems = HashSet<List<String>>()

        fun visit(node: SemanticsNode) {
            if (NodeRules.isExcluded(node)) return
            val path = paths[node.id]
            if (path != null) {
                if (LAZY_ITEM in path.segments && !seenLazyItems.add(path.segments)) return
                if (NodeRules.isKept(node)) candidate(node, path)
            }
            for (child in node.children) visit(child)
        }

        private fun candidate(node: SemanticsNode, path: NodePath) {
            val tier = tierOf(node) ?: return
            total++
            if (entries.size < limit) entries += RegionInventoryEntry(NodeTargets.of(node, path), tier)
        }

        private fun tierOf(node: SemanticsNode): InventoryTier? {
            val visible = visibleArea(NodeBounds.bounds(node))
            if (!(visible > 0)) return null
            return when {
                NodeRules.isActionable(node) -> InventoryTier.Interactive
                NodeRules.role(node) == Role.Image -> InventoryTier.Content
                NodeRules.isMaskable(node) && visible / windowArea >= LARGE_TEXT_AREA -> InventoryTier.Content
                else -> null
            }
        }

        /** The area of [bounds] inside the host, in pixels. */
        private fun visibleArea(bounds: RectF): Double {
            val w = minOf(bounds.right, host.width.toFloat()) - maxOf(bounds.left, 0f)
            val h = minOf(bounds.bottom, host.height.toFloat()) - maxOf(bounds.top, 0f)
            if (!(w > 0) || !(h > 0)) return 0.0
            return w.toDouble() * h.toDouble()
        }
    }
}
