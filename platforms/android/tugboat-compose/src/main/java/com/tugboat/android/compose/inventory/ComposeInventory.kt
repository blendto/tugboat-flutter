package com.tugboat.android.compose.inventory

import android.graphics.RectF
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.identity.NodePaths
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRoles
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.RegionInventoryEntry

/** Scene inventory entries from a Compose host's merged semantics tree. */
internal object ComposeInventory {
    private const val CONTENT_TIER = "content"
    private const val INTERACTIVE_TIER = "interactive"
    private const val LARGE_TEXT_AREA = 0.02

    fun of(host: android.view.View, root: SemanticsNode?): List<RegionInventoryEntry> {
        if (root == null) return emptyList()
        val width = host.width.toDouble()
        val height = host.height.toDouble()
        if (width <= 0 || height <= 0) return emptyList()
        val out = ArrayList<RegionInventoryEntry>()
        val seenLazyItem = HashSet<String>()
        walk(root, root, width, height, out, seenLazyItem)
        return out
    }

    private fun walk(
        root: SemanticsNode,
        node: SemanticsNode,
        width: Double,
        height: Double,
        out: MutableList<RegionInventoryEntry>,
        seenLazyItem: MutableSet<String>,
    ) {
        if (NodeRules.isExcluded(node)) return
        val path = NodePaths.build(root, node)
        if (path != null && path.segments.size == 1 && path.segments[0] == "[item]") {
            if (!seenLazyItem.add(path.segments[0])) return
        }
        if (path != null && NodeRules.isKept(node)) {
            entryFor(root, node, path, width, height)?.let(out::add)
        }
        for (child in node.children) walk(root, child, width, height, out, seenLazyItem)
    }

    private fun entryFor(
        root: SemanticsNode,
        node: SemanticsNode,
        path: com.tugboat.android.compose.identity.NodePath,
        width: Double,
        height: Double,
    ): RegionInventoryEntry? {
        val bounds = NodeBounds.bounds(node)
        val norm = normalize(bounds, width, height) ?: return null
        val actionable = NodeRules.isActionable(node)
        val tier = when {
            actionable -> INTERACTIVE_TIER
            NodeRules.role(node) == Role.Image -> CONTENT_TIER
            NodeRules.isMaskable(node) && norm.width * norm.height >= LARGE_TEXT_AREA -> CONTENT_TIER
            else -> return null
        }
        return RegionInventoryEntry(
            pathSegments = path.segments,
            widgetType = NodeRoles.token(node),
            role = if (tier == CONTENT_TIER) "display" else NodeRoles.role(node),
            actions = if (actionable) NodeRoles.actions(node) else emptyList(),
            enabled = NodeRoles.enabled(node),
            tag = NodeRules.alias(node),
            inListItem = path.inListItem,
            bounds = bounds,
            tier = tier,
            structuralFingerprint = path.segments.joinToString("/"),
        )
    }

    private fun normalize(bounds: RectF, width: Double, height: Double): Normalized? {
        val left = (bounds.left / width).coerceIn(0.0, 1.0)
        val top = (bounds.top / height).coerceIn(0.0, 1.0)
        val right = (bounds.right / width).coerceIn(0.0, 1.0)
        val bottom = (bounds.bottom / height).coerceIn(0.0, 1.0)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return null
        return Normalized(left, top, w, h)
    }

    private data class Normalized(val left: Double, val top: Double, val width: Double, val height: Double)

}
